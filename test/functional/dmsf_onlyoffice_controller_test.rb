# frozen_string_literal: true

# Redmine plugin for Document Management System "Features"
#
# Marco Tenti <tentimarco0@gmail.com>, Karel Pičman <karel.picman@kontron.com>
#
# This file is part of Redmine DMSF plugin.
#
# Redmine DMSF plugin is free software: you can redistribute it and/or modify it under the terms of the GNU General
# Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any
# later version.
#
# Redmine DMSF plugin is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
# the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License along with Redmine DMSF plugin. If not, see
# <https://www.gnu.org/licenses/>.

require File.expand_path('../test_helper', __dir__)
require 'tempfile'

# Exercise signed server-to-server requests independently of browser sessions.
class DmsfOnlyofficeControllerTest < RedmineDmsf::Test::TestCase
  def setup
    super
    @revision = @file1.last_revision
    @key = RedmineDmsf::OnlyOffice.document_key(@file1, @revision)
    @tempfiles = []
    RedmineDmsf.stubs(:onlyoffice_document_server_url).returns('https://office.example.test')
    RedmineDmsf.stubs(:onlyoffice_document_server_internal_url).returns('')
    RedmineDmsf.stubs(:onlyoffice_redmine_internal_url).returns('')
    RedmineDmsf.stubs(:onlyoffice_jwt_secret).returns('onlyoffice-test-secret')
    RedmineDmsf.stubs(:onlyoffice_jwt_algorithm).returns('HS256')
    RedmineDmsf.stubs(:onlyoffice_jwt_header).returns('Authorization')
    RedmineDmsf.stubs(:onlyoffice_token_ttl).returns(3600)
    RedmineDmsf.stubs(:onlyoffice_session_ttl).returns(30.days.to_i)
    RedmineDmsf.stubs(:onlyoffice_snapshot_limit).returns(3)
    RedmineDmsf.stubs(:onlyoffice_editable_extensions).returns(%w[txt docx])
    RedmineDmsf.stubs(:onlyoffice_version_constant).returns(DmsfFileRevision::MINOR_VERSION)
    DmsfMailer.stubs(:deliver_files_updated)
    @callback_token = storage_token('callback')
  end

  def teardown
    @tempfiles.each(&:close!)
    User.current = nil
    super
  end

  def test_disabled_integration_returns_not_found
    RedmineDmsf.stubs(:onlyoffice_document_server_url).returns('')
    get "/dmsf/files/#{@file1.id}/onlyoffice/view"
    assert_response :not_found
  end

  def test_authorized_user_can_open_the_viewer
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    get "/dmsf/files/#{@file1.id}/onlyoffice/view"
    assert_response :success
    assert_select '#dmsf-onlyoffice-editor'
    assert_includes response.body, "#{@key}-view"
  end

  def test_refresh_returns_a_new_configuration_and_the_current_revision_identity
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    get "/dmsf/files/#{@file1.id}/onlyoffice/refresh", params: { mode: 'view', editor_type: 'mobile' }
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @revision.id, body['revision_id']
    assert_equal @revision.version, body['version']
    assert_equal "#{@key}-view", body.dig('config', 'document', 'key')
    assert_equal 'mobile', body.dig('config', 'type')
  end

  def test_invalid_action_link_is_rejected
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    get "/dmsf/files/#{@file1.id}/onlyoffice/view", params: { action_link: '[]' }
    assert_response :bad_request
  end

  def test_action_link_is_included_in_the_signed_editor_configuration
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    action_link = { action: { type: 'bookmark', data: 'example-bookmark' } }
    get "/dmsf/files/#{@file1.id}/onlyoffice/refresh", params: { mode: 'view', action_link: action_link.to_json }
    assert_response :success
    config = JSON.parse(response.body)['config']
    assert_equal action_link.deep_stringify_keys, config.dig('editorConfig', 'actionLink')
    signed = RedmineDmsf::OnlyOffice.jwt_decode(config['token'], 'onlyoffice-test-secret')
    assert_equal config['editorConfig']['actionLink'], signed.dig('editorConfig', 'actionLink')
  end

  def test_form_filling_is_not_available_for_non_pdf_documents
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    get "/dmsf/files/#{@file1.id}/onlyoffice/edit", params: { mode: 'fill' }
    assert_response :forbidden
  end

  def test_edit_requires_file_manipulation_permission
    @role_manager.remove_permission! :file_manipulation
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    get "/dmsf/files/#{@file1.id}/onlyoffice/edit"
    assert_response :forbidden
  end

  def test_edit_rejects_a_file_locked_by_another_user
    DmsfFile.any_instance.stubs(:locked_for_user?).returns(true)
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    get "/dmsf/files/#{@file1.id}/onlyoffice/edit"
    assert_response :forbidden
  end

  def test_signed_callback_works_when_login_is_required
    with_settings login_required: '1' do
      post_callback(status: 4)
      assert_callback_error 0
    end
  end

  def test_invalid_callback_token_is_rejected_without_a_login_redirect
    with_settings login_required: '1' do
      post_callback(status: 4, token: 'invalid-token')
      assert_callback_error 1
    end
  end

  def test_callback_requires_a_matching_document_key
    post_callback(status: 4, key: 'another-document')
    assert_callback_error 1
  end

  def test_acknowledged_statuses_do_not_create_revisions
    [1, 4].each do |status|
      assert_no_difference 'DmsfFileRevision.count' do
        post_callback(status: status)
      end
      assert_callback_error 0
    end
  end

  def test_force_save_is_durable_without_creating_a_revision
    stub_edited_document
    assert_no_difference 'DmsfFileRevision.count' do
      assert_difference 'DmsfOnlyofficeRecovery.count', 1 do
        post_callback(status: 6, forcesavetype: 0, userdata: 'save-request-1')
      end
    end
    assert_callback_error 0
    capture = DmsfOnlyofficeRecovery.last
    assert_equal 'snapshot', capture.kind
    assert_equal 'Edited by ONLYOFFICE', capture.payload.download
    assert_equal 'save-request-1', capture.metadata['userdata']
    assert_equal 'snapshot', capture.dmsf_onlyoffice_session.state
  end

  def test_repeated_force_save_deduplicates_content_without_consuming_the_final_save
    stub_edited_document
    post_callback(status: 6, userdata: 'first')
    assert_callback_error 0
    assert_no_difference 'DmsfOnlyofficeRecovery.count' do
      post_callback(status: 6, userdata: 'second')
    end
    assert_callback_error 0
    assert_equal %w[first second], DmsfOnlyofficeRecovery.last.metadata['request_ids']
    assert_difference 'DmsfFileRevision.count', 1 do
      post_callback(status: 2)
    end
    assert_callback_error 0
  end

  def test_late_force_save_does_not_regress_a_saved_session
    stub_edited_document
    post_callback(status: 2)
    assert_callback_error 0
    assert_no_difference 'DmsfOnlyofficeRecovery.count' do
      post_callback(status: 6, userdata: 'late-request')
    end
    assert_callback_error 0
    assert_equal 'saved', DmsfOnlyofficeSession.find_by!(document_key: @key).state
    assert_includes DmsfOnlyofficeRecovery.last.metadata['request_ids'], 'late-request'
  end

  def test_late_force_save_with_different_bytes_is_preserved_as_a_conflict
    stub_edited_document
    post_callback(status: 2)
    assert_callback_error 0
    late = temporary_document('Unaccounted late changes')
    RedmineDmsf::OnlyOffice.stubs(:download_to_tempfile).returns(late)
    post_callback(status: 6)
    assert_callback_error 0
    capture = DmsfOnlyofficeRecovery.last
    assert_equal 'conflict', capture.kind
    assert_equal 'Unaccounted late changes', capture.payload.download
    assert_equal 'saved', capture.dmsf_onlyoffice_session.state
  end

  def test_final_publication_releases_completed_working_snapshots_and_redundant_payload
    stub_edited_document
    post_callback(status: 6, userdata: 'completed-draft-request')
    assert_callback_error 0
    snapshot = DmsfOnlyofficeRecovery.last
    post_callback(status: 2)
    assert_callback_error 0
    assert_not DmsfOnlyofficeRecovery.exists?(snapshot.id)
    final = DmsfOnlyofficeRecovery.last
    assert_equal 'imported', final.state
    assert_not final.payload.attached?
    assert_equal 'Edited by ONLYOFFICE', final.restored_revision.file.download
    assert_includes final.metadata['request_ids'], 'completed-draft-request'
  end

  def test_document_server_errors_preserve_returned_bytes_without_publishing
    stub_edited_document
    [3, 7].each do |status|
      assert_no_difference 'DmsfFileRevision.count' do
        post_callback(status: status)
      end
      assert_callback_error 0
      assert_equal 'Edited by ONLYOFFICE', DmsfOnlyofficeRecovery.last.payload.download
    end
  end

  def test_failed_byte_acquisition_is_not_acknowledged
    RedmineDmsf::OnlyOffice.stubs(:download_to_tempfile).raises(RedmineDmsf::OnlyOffice::Error, 'Unavailable')
    assert_no_difference 'DmsfOnlyofficeRecovery.count' do
      post_callback(status: 6)
    end
    assert_response :service_unavailable
    assert_equal 1, JSON.parse(response.body).fetch('error')
  end

  def test_completed_edit_creates_a_revision_without_overwriting_the_source
    original_content = @revision.file.download
    original_values = @revision.custom_field_values.to_h { |value| [value.custom_field_id, value.value] }
    stub_edited_document

    assert_difference 'DmsfFileRevision.count', 1 do
      post_callback(status: 2)
    end
    assert_callback_error 0

    saved = DmsfFileRevision.find_by!(onlyoffice_key: @key)
    assert_equal @revision.id, saved.source_revision.id
    assert_equal @jsmith.id, saved.user_id
    assert_equal @revision.title, saved.title
    assert_equal @revision.description, saved.description
    assert_nil saved.workflow
    assert_nil saved.dmsf_workflow_id
    assert_equal(original_values, saved.custom_field_values.to_h { |value| [value.custom_field_id, value.value] })
    assert_equal 'Edited by ONLYOFFICE', saved.file.download
    assert_equal original_content, @revision.reload.file.download
  end

  def test_duplicate_callback_does_not_create_another_revision
    stub_edited_document
    post_callback(status: 2)
    assert_callback_error 0

    assert_no_difference 'DmsfFileRevision.count' do
      post_callback(status: 2)
    end
    assert_callback_error 0
  end

  def test_a_different_final_retry_preserves_content_and_keeps_the_published_revision
    stub_edited_document
    post_callback(status: 2)
    assert_callback_error 0
    saved = DmsfFileRevision.find_by!(onlyoffice_key: @key)
    RedmineDmsf::OnlyOffice.stubs(:download_to_tempfile).returns(temporary_document('Different final bytes'))
    assert_no_difference 'DmsfFileRevision.count' do
      post_callback(status: 2)
    end
    assert_callback_error 0
    conflict = DmsfOnlyofficeRecovery.find_by!(kind: 'conflict')
    assert_equal 'Different final bytes', conflict.payload.download
    assert_equal 'Edited by ONLYOFFICE', saved.reload.file.download
    warning = conflict.dmsf_onlyoffice_session.last_error
    post_callback(status: 1, users: [@jsmith.id.to_s])
    assert_callback_error 0
    post_callback(status: 4)
    assert_callback_error 0
    session = conflict.dmsf_onlyoffice_session.reload
    assert_equal 'saved', session.state
    assert_equal warning, session.last_error
    assert session.closed_at
  end

  def test_final_retries_after_pruning_do_not_resurrect_history_and_still_preserve_differing_bytes
    stub_edited_document
    post_callback(status: 2)
    assert_callback_error 0
    saved = DmsfFileRevision.find_by!(onlyoffice_key: @key)
    User.current = @jsmith
    saved.destroy!
    assert_no_difference ['DmsfFileRevision.count', 'DmsfOnlyofficeHistory.count'] do
      post_callback(status: 2)
    end
    assert_callback_error 0
    assert_nil DmsfFileRevision.find_by(onlyoffice_key: @key)

    RedmineDmsf::OnlyOffice.stubs(:download_to_tempfile).returns(temporary_document('Late bytes after pruning'))
    assert_no_difference ['DmsfFileRevision.count', 'DmsfOnlyofficeHistory.count'] do
      post_callback(status: 2)
    end
    assert_callback_error 0
    assert_equal 'Late bytes after pruning', DmsfOnlyofficeRecovery.find_by!(kind: 'conflict').payload.download
  end

  def test_collaborative_callback_uses_its_signed_actor_instead_of_the_session_owner
    DmsfOnlyofficeSession.register!(file: @file1, revision: @revision, user: @jsmith,
                                    mode: 'edit', document_key: @key)
    DmsfOnlyofficeSession.register!(file: @file1, revision: @revision, user: @admin,
                                    mode: 'review', document_key: @key)
    stub_edited_document
    post_callback(status: 2, token: storage_token('callback', user: @admin, mode: 'review'))
    assert_callback_error 0
    saved = DmsfFileRevision.find_by!(onlyoffice_key: @key)
    assert_equal @admin.id, saved.user_id
    session = DmsfOnlyofficeSession.find_by!(document_key: @key)
    assert_equal @jsmith.id, session.user_id
    assert_includes session.participants, @admin.id.to_s
  end

  def test_view_only_session_cannot_save
    assert_no_difference 'DmsfFileRevision.count' do
      post_callback(status: 2, token: storage_token('callback', mode: 'view'))
    end
    assert_callback_error 1
  end

  def test_callback_rechecks_file_locks
    stub_edited_document
    DmsfFile.any_instance.stubs(:locked_for_user?).returns(true)
    assert_no_difference 'DmsfFileRevision.count' do
      post_callback(status: 2)
    end
    assert_callback_error 0
    assert_equal 'pending', DmsfOnlyofficeRecovery.last.state
    assert_match(/locked/, DmsfOnlyofficeRecovery.last.reason)
    assert_equal 'Edited by ONLYOFFICE', DmsfOnlyofficeRecovery.last.payload.download
  end

  def test_callback_rechecks_the_editing_users_permissions
    stub_edited_document
    @role_manager.remove_permission! :file_manipulation
    assert_no_difference 'DmsfFileRevision.count' do
      post_callback(status: 2)
    end
    assert_callback_error 0
    assert_equal 'pending', DmsfOnlyofficeRecovery.last.state
    assert_match(/allowed/, DmsfOnlyofficeRecovery.last.reason)
  end

  def test_callback_rejects_a_stale_source_revision
    newer = @revision.clone
    newer.user = @jsmith
    newer.save!
    stub_edited_document

    assert_no_difference 'DmsfFileRevision.count' do
      post_callback(status: 2)
    end
    assert_callback_error 0
    assert_nil DmsfFileRevision.find_by(onlyoffice_key: @key)
    assert_equal 'Edited by ONLYOFFICE', DmsfOnlyofficeRecovery.last.payload.download
    assert_match(/newer/, DmsfOnlyofficeRecovery.last.reason)
  end

  def test_actual_callback_format_updates_the_stored_filename
    stub_edited_document
    post_callback(status: 2, filetype: 'docx')
    assert_callback_error 0
    saved = DmsfFileRevision.find_by!(onlyoffice_key: @key)
    assert_equal '.docx', File.extname(saved.name)
    assert_equal saved.name, saved.file.blob.filename.to_s
  end

  def test_filled_documents_never_replace_the_form_template
    stub_edited_document
    assert_no_difference 'DmsfFileRevision.count' do
      post_callback(status: 2, token: storage_token('callback', mode: 'fill'))
    end
    assert_callback_error 0
    capture = DmsfOnlyofficeRecovery.last
    assert_equal 'form', capture.kind
    assert_equal 'submitted', capture.dmsf_onlyoffice_session.state
    assert capture.dmsf_onlyoffice_session.closed_at
    assert_equal @revision.id, @file1.reload.dmsf_file_revisions.visible.first.id
  end

  def test_submitted_form_data_is_saved_with_the_document
    stub_edited_document
    forms_url = 'https://office.example.test/cache/form-data.json'
    forms = temporary_document('[{"key":"reference","value":"A-42"}]')
    RedmineDmsf::OnlyOffice.stubs(:download_to_tempfile).with(forms_url, max_bytes: 2.megabytes).returns(forms)
    post_callback(status: 6, forcesavetype: 3, formsdataurl: forms_url)
    assert_callback_error 0
    assert_equal [{ 'key' => 'reference', 'value' => 'A-42' }], DmsfOnlyofficeRecovery.last.metadata['forms_data']
  end

  def test_final_revision_preserves_the_signed_history_and_changes_archive
    stub_edited_document
    changes_url = 'https://office.example.test/cache/changes.zip'
    archive = temporary_document('change archive')
    RedmineDmsf::OnlyOffice.stubs(:download_to_tempfile).with(changes_url, max_bytes: anything).returns(archive)
    post_callback(status: 2, changesurl: changes_url,
                  history: { serverVersion: '10.0.0', changes: [{ user: { id: @jsmith.id.to_s } }] })
    assert_callback_error 0
    saved = DmsfFileRevision.find_by!(onlyoffice_key: @key)
    history = DmsfOnlyofficeHistory.find_by!(dmsf_file_revision: saved)
    assert_equal '10.0.0', history.metadata['serverVersion']
    assert_equal @revision.id, history.source_revision_id
    assert_equal 'change archive', history.changes_archive.download
  end

  def test_signed_download_works_when_login_is_required
    with_settings login_required: '1' do
      get "/dmsf/files/#{@file1.id}/onlyoffice/download/#{@revision.name}",
          params: { token: storage_token('download') }
      assert_response :success
    end
  end

  def test_invalid_download_token_is_rejected_without_a_login_redirect
    with_settings login_required: '1' do
      get "/dmsf/files/#{@file1.id}/onlyoffice/download/#{@revision.name}", params: { token: 'invalid-token' }
      assert_response :not_found
    end
  end

  def test_early_save_rejection_preserves_the_current_user
    User.current = @jsmith
    controller = DmsfOnlyofficeController.new

    assert_raises RedmineDmsf::OnlyOffice::InvalidToken do
      controller.send(:save_revision, {}, { 'mode' => 'view' })
    end
    assert_equal @jsmith, User.current
  end

  private

  def storage_token(purpose, mode: 'edit', user: @jsmith)
    RedmineDmsf::OnlyOffice.storage_token(
      file: @file1, revision: @revision, user: user, purpose: purpose, key: @key, mode: mode
    )
  end

  def post_callback(status:, token: @callback_token, key: @key, **extra)
    payload = { key: key, status: status, url: 'https://office.example.test/cache/edited.txt' }.merge(extra)
    jwt = RedmineDmsf::OnlyOffice.jwt_encode(payload, 'onlyoffice-test-secret')
    post "/dmsf/onlyoffice/callback?token=#{token}",
         params: { token: jwt }.to_json, headers: { 'CONTENT_TYPE' => 'application/json' }
  end

  def assert_callback_error(expected)
    assert_response :success
    assert_equal expected, JSON.parse(response.body).fetch('error')
  end

  def stub_edited_document
    files = Array.new(6) { temporary_document('Edited by ONLYOFFICE') }
    RedmineDmsf::OnlyOffice.stubs(:download_to_tempfile).returns(*files)
  end

  def temporary_document(content)
    tempfile = Tempfile.new(['dmsf-onlyoffice-test-', '.txt'])
    @tempfiles << tempfile
    tempfile.write(content)
    tempfile.rewind
    tempfile
  end
end
