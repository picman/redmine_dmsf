# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)
require 'tempfile'

# Browser actions must preserve authorization, content, and operation identity.
class DmsfOnlyofficeActionsControllerTest < RedmineDmsf::Test::TestCase
  def setup
    super
    @revision = @file1.last_revision
    @tempfiles = []
    RedmineDmsf.stubs(:onlyoffice_document_server_url).returns('https://office.example.test')
    RedmineDmsf.stubs(:onlyoffice_jwt_secret).returns('onlyoffice-test-secret')
    RedmineDmsf.stubs(:onlyoffice_redmine_internal_url).returns('')
    RedmineDmsf.stubs(:onlyoffice_force_save_enabled?).returns(true)
    Redmine::Hook.stubs(:call_hook).returns([])
    DmsfMailer.stubs(:deliver_files_updated)
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
  end

  def teardown
    @tempfiles.each(&:close!)
    User.current = nil
    super
  end

  def test_copy_requires_file_manipulation_permission_before_downloading
    @role_manager.remove_permission! :file_manipulation
    RedmineDmsf::OnlyOffice.expects(:download_to_tempfile).never

    assert_no_difference 'DmsfFile.count' do
      post "/dmsf/files/#{@file1.id}/onlyoffice/save-as",
           params: { title: 'Denied copy', file_type: 'txt', url: 'https://office.example.test/cache/copy.txt' }
    end

    assert_response :forbidden
  end

  def test_copy_preserves_the_source_and_creates_an_independent_document
    original = @revision.file.download
    RedmineDmsf::OnlyOffice.stubs(:download_to_tempfile).returns(tempfile('Edited copy'))

    assert_difference 'DmsfFile.count', 1 do
      post "/dmsf/files/#{@file1.id}/onlyoffice/save-as",
           params: { title: 'Independent copy', file_type: 'txt',
                     url: 'https://office.example.test/cache/copy.txt', folder_id: '' }
    end

    assert_response :success
    copied = DmsfFile.find(JSON.parse(response.body).fetch('file_id'))
    assert_not_equal @file1.id, copied.id
    assert_equal 'Edited copy', copied.last_revision.file.download
    assert_equal original, @revision.reload.file.download
    assert_equal @revision.id, copied.last_revision.source_dmsf_file_revision_id
    assert_equal [1, 0], [copied.last_revision.major_version, copied.last_revision.minor_version]
  end

  def test_copy_cannot_write_into_a_folder_locked_by_another_user
    User.current = @admin
    @folder1.lock!
    User.current = nil
    RedmineDmsf::OnlyOffice.stubs(:download_to_tempfile).returns(tempfile('Edited copy'))

    assert_no_difference 'DmsfFile.count' do
      post "/dmsf/files/#{@file1.id}/onlyoffice/save-as",
           params: { title: 'Locked destination', file_type: 'txt',
                     url: 'https://office.example.test/cache/copy.txt', folder_id: @folder1.id }
    end

    assert_response :unprocessable_entity
  end

  def test_copy_does_not_commit_a_document_if_its_bytes_cannot_be_uploaded
    DmsfOnlyofficeBlob.expects(:upload!).raises(IOError, 'storage unavailable')

    assert_no_difference ['DmsfFile.count', 'DmsfFileRevision.count'] do
      assert_raises IOError do
        DmsfOnlyofficeDocumentCreator.call(source: @revision, user: @jsmith,
                                           io: tempfile('Unsaved copy'), filename: 'unsaved-copy.txt')
      end
    end
  end

  def test_rename_rejects_a_stale_head_without_changing_the_document
    original = @revision.name
    RedmineDmsf::OnlyOffice.expects(:command).never

    post "/dmsf/files/#{@file1.id}/onlyoffice/rename",
         params: { title: 'Stale rename', expected_revision_id: 0 }

    assert_response :unprocessable_entity
    assert_equal original, @revision.reload.name
  end

  def test_rename_with_an_unknown_session_does_not_commit_before_reporting_the_error
    original = @revision.name
    RedmineDmsf::OnlyOffice.expects(:command).never

    post "/dmsf/files/#{@file1.id}/onlyoffice/rename",
         params: { title: 'Invalid session rename', expected_revision_id: @revision.id, key: 'unknown-session' }

    assert_response :not_found
    assert_equal original, @revision.reload.name
  end

  def test_pdf_publication_rejects_an_unapproved_revision_without_calling_onlyoffice
    RedmineDmsf::OnlyOffice.expects(:convert).never

    assert_no_difference ['DmsfOnlyofficeOperation.count', 'DmsfFile.count'] do
      post "/dmsf/files/#{@file1.id}/onlyoffice/pdf", params: { revision_id: @revision.id }
    end

    assert_response :unprocessable_entity
  end

  def test_pdf_publication_retry_returns_the_same_document_without_a_second_upload_hook
    @revision.update!(workflow: DmsfWorkflow::STATE_APPROVED)
    RedmineDmsf::OnlyOffice.expects(:convert).once
                          .returns('endConvert' => true, 'fileUrl' => 'https://office.example.test/cache/export.pdf')
    RedmineDmsf::OnlyOffice.stubs(:download_to_tempfile).returns(tempfile('%PDF-1.7 retained output'))
    Redmine::Hook.expects(:call_hook).with(:dmsf_helper_upload_after_commit, kind_of(Hash)).once

    assert_difference 'DmsfFile.count', 1 do
      post "/dmsf/files/#{@file1.id}/onlyoffice/pdf", params: { revision_id: @revision.id }
    end
    assert_response :success
    created_id = JSON.parse(response.body).fetch('file_id')
    operation = DmsfOnlyofficeOperation.find_by!(result_file_id: created_id)

    assert_no_difference 'DmsfFile.count' do
      post "/dmsf/files/#{@file1.id}/onlyoffice/pdf", params: { operation_id: operation.id }
    end

    assert_response :success
    assert_equal created_id, JSON.parse(response.body).fetch('file_id')
    assert_equal 'completed', operation.reload.state
    assert_equal '%PDF-1.7 retained output', DmsfFile.find(created_id).last_revision.file.download
  end

  def test_force_save_requires_participation_in_the_collaborative_session
    session = DmsfOnlyofficeSession.register!(file: @file1, revision: @revision, user: @admin,
                                              mode: 'edit', document_key: 'another-authors-session')
    RedmineDmsf::OnlyOffice.expects(:command).never

    post "/dmsf/files/#{@file1.id}/onlyoffice/forcesave", params: { key: session.document_key }

    assert_response :forbidden
  end

  def test_pending_pdf_does_not_publish_until_the_conversion_finishes
    @revision.update!(workflow: DmsfWorkflow::STATE_APPROVED)
    RedmineDmsf::OnlyOffice.stubs(:convert).returns(
      { 'endConvert' => false },
      { 'endConvert' => true, 'fileUrl' => 'https://office.example.test/cache/export.pdf' }
    )
    RedmineDmsf::OnlyOffice.stubs(:download_to_tempfile).returns(tempfile('%PDF-1.7 completed later'))

    assert_no_difference 'DmsfFile.count' do
      post "/dmsf/files/#{@file1.id}/onlyoffice/pdf", params: { revision_id: @revision.id }
    end
    assert_response :accepted
    operation_id = JSON.parse(response.body).fetch('operation_id')
    assert_equal 'pending', DmsfOnlyofficeOperation.find(operation_id).state

    assert_difference 'DmsfFile.count', 1 do
      post "/dmsf/files/#{@file1.id}/onlyoffice/pdf", params: { operation_id: operation_id }
    end

    assert_response :success
    assert_equal 'completed', DmsfOnlyofficeOperation.find(operation_id).state
  end

  def test_document_builder_polling_reuses_the_remote_key_and_imports_the_returned_file
    @revision.update!(name: 'template.docx')
    RedmineDmsf.stubs(:onlyoffice_template_revision_ids).returns([@revision.id])
    RedmineDmsf::OnlyOffice.expects(:build_document).with do |request|
      request[:async] == true && request[:url].present? && request[:key].nil?
    end.returns('key' => 'remote-builder-job', 'end' => false)
    RedmineDmsf::OnlyOffice.expects(:build_document).with do |request|
      request[:async] == true && request[:key] == 'remote-builder-job'
    end.returns('key' => 'remote-builder-job', 'end' => true,
                'urls' => { 'output.docx' => 'https://office.example.test/cache/output.docx' })
    RedmineDmsf::OnlyOffice.stubs(:download_to_tempfile).returns(tempfile('Generated document bytes'))

    assert_no_difference 'DmsfFile.count' do
      post "/dmsf/files/#{@file1.id}/onlyoffice/from-template",
           params: { template_id: @revision.id, title: 'Generated report' }
    end
    assert_response :accepted
    operation_id = JSON.parse(response.body).fetch('operation_id')
    assert_equal 'remote-builder-job', DmsfOnlyofficeOperation.find(operation_id).remote_key

    assert_difference 'DmsfFile.count', 1 do
      post "/dmsf/files/#{@file1.id}/onlyoffice/from-template", params: { operation_id: operation_id }
    end

    assert_response :success
    generated = DmsfFile.find(JSON.parse(response.body).fetch('file_id'))
    assert_equal 'Generated report.docx', generated.name
    assert_equal 'Generated document bytes', generated.last_revision.file.download
  end

  def test_another_authors_operation_cannot_be_polled_even_on_the_same_document
    @revision.update!(workflow: DmsfWorkflow::STATE_APPROVED)
    operation = DmsfOnlyofficeOperation.create!(
      request_key: 'private-operation', kind: 'pdf', dmsf_file: @file1,
      source_revision: @revision, user: @admin, filename: 'private-export.pdf', parameters: {}
    )
    RedmineDmsf::OnlyOffice.expects(:convert).never

    post "/dmsf/files/#{@file1.id}/onlyoffice/pdf", params: { operation_id: operation.id }

    assert_response :not_found
  end

  def test_second_collaborator_can_request_a_force_save_on_the_shared_key
    key = 'shared-authors-session'
    first = DmsfOnlyofficeSession.register!(file: @file1, revision: @revision, user: @admin,
                                           mode: 'edit', document_key: key)
    second = DmsfOnlyofficeSession.register!(file: @file1, revision: @revision, user: @jsmith,
                                            mode: 'edit', document_key: key)
    RedmineDmsf::OnlyOffice.expects(:command).with('forcesave', has_entries(key: key))
                          .returns('error' => 0, 'key' => key)

    assert_no_difference 'DmsfFileRevision.count' do
      post "/dmsf/files/#{@file1.id}/onlyoffice/forcesave", params: { key: key }
    end

    assert_response :success
    assert_equal first.id, second.id
    assert_equal true, JSON.parse(response.body).fetch('pending')
  end

  def test_pdf_of_a_historical_revision_requires_history_permission
    @revision.update!(workflow: DmsfWorkflow::STATE_APPROVED)
    newer = @revision.clone
    newer.minor_version = 2
    newer.reset_workflow
    newer.save!
    @role_manager.remove_permission! :view_dmsf_file_revisions
    RedmineDmsf::OnlyOffice.expects(:convert).never

    assert_no_difference 'DmsfOnlyofficeOperation.count' do
      post "/dmsf/files/#{@file1.id}/onlyoffice/pdf", params: { revision_id: @revision.id }
    end
    assert_response :unprocessable_entity
  end

  def test_pdf_poll_rechecks_history_permission_after_the_source_is_superseded
    @revision.update!(workflow: DmsfWorkflow::STATE_APPROVED)
    RedmineDmsf::OnlyOffice.expects(:convert).once.returns('endConvert' => false)
    post "/dmsf/files/#{@file1.id}/onlyoffice/pdf", params: { revision_id: @revision.id }
    operation_id = JSON.parse(response.body).fetch('operation_id')
    newer = @revision.clone
    newer.minor_version = 2
    newer.reset_workflow
    newer.save!
    @role_manager.remove_permission! :view_dmsf_file_revisions

    post "/dmsf/files/#{@file1.id}/onlyoffice/pdf", params: { operation_id: operation_id }
    assert_response :unprocessable_entity
    assert_nil DmsfOnlyofficeOperation.find(operation_id).result_file_id
  end

  def test_pdf_provenance_is_the_approved_source_even_with_a_newer_head
    @role_manager.add_permission! :view_dmsf_file_revisions
    @revision.update!(workflow: DmsfWorkflow::STATE_APPROVED)
    newer = @revision.clone
    newer.minor_version = 2
    newer.reset_workflow
    newer.save!
    RedmineDmsf::OnlyOffice.stubs(:convert).returns('endConvert' => true,
                                                    'fileUrl' => 'https://office.example.test/result.pdf')
    RedmineDmsf::OnlyOffice.stubs(:download_to_tempfile).returns(tempfile('%PDF-1.7 approved source'))

    post "/dmsf/files/#{@file1.id}/onlyoffice/pdf", params: { revision_id: @revision.id }
    assert_response :success
    result = DmsfFile.find(JSON.parse(response.body).fetch('file_id'))
    assert_equal @revision.id, result.last_revision.source_dmsf_file_revision_id
  end

  def test_a_stale_operation_cannot_replace_a_completed_result_with_an_error
    operation = DmsfOnlyofficeOperation.create!(
      kind: 'pdf', request_key: SecureRandom.uuid,
      dmsf_file: @file1, source_revision: @revision, user: @jsmith, filename: 'export.pdf'
    )
    stale = DmsfOnlyofficeOperation.find(operation.id)
    operation.update!(state: 'completed', result_file: @file2)

    stale.update_if_pending!(state: 'failed', last_error: 'Late remote error')
    assert_equal 'completed', stale.reload.state
    assert_equal @file2.id, stale.result_file_id
    assert_nil stale.last_error
  end

  def test_late_remote_errors_return_the_already_completed_operation
    @revision.update!(workflow: DmsfWorkflow::STATE_APPROVED)
    responses = [{ 'error' => 5 }, { 'endConvert' => 'invalid' }, { 'endConvert' => true }]
    responses.each do |remote_response|
      operation = DmsfOnlyofficeOperation.create!(
        kind: 'pdf', request_key: SecureRandom.uuid,
        dmsf_file: @file1, source_revision: @revision, user: @jsmith, filename: 'export.pdf'
      )
      RedmineDmsf::OnlyOffice.expects(:convert).with do |_parameters|
        DmsfOnlyofficeOperation.find(operation.id).update!(state: 'completed', result_file: @file1)
        true
      end.returns(remote_response)

      post "/dmsf/files/#{@file1.id}/onlyoffice/pdf", params: { operation_id: operation.id }
      assert_response :success
      assert_equal @file1.id, JSON.parse(response.body).fetch('file_id')
      assert_equal 'completed', operation.reload.state
      assert_nil operation.last_error
    end
  end

  def test_template_provenance_and_destination_are_independent
    post '/login', params: { username: 'admin', password: 'admin' }
    template = @file2.last_revision
    template.update!(name: 'source-template.docx')
    RedmineDmsf.stubs(:onlyoffice_template_revision_ids).returns([template.id])
    RedmineDmsf::OnlyOffice.stubs(:build_document).returns(
      'end' => true, 'urls' => { 'output.docx' => 'https://office.example.test/cache/output.docx' }
    )
    RedmineDmsf::OnlyOffice.stubs(:download_to_tempfile).returns(tempfile('Generated template content'))

    post "/dmsf/files/#{@file1.id}/onlyoffice/from-template",
         params: { template_id: template.id, title: 'Document from external template' }
    assert_response :success
    result = DmsfFile.find(JSON.parse(response.body).fetch('file_id'))
    assert_equal @file1.project_id, result.project_id
    assert_equal template.id, result.last_revision.source_dmsf_file_revision_id
  end

  private

  def tempfile(content)
    file = Tempfile.new(['onlyoffice-actions-', '.txt'])
    @tempfiles << file
    file.write(content)
    file.rewind
    file
  end
end
