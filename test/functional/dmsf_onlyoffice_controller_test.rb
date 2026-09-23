# frozen_string_literal: true

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
    [1, 4, 6].each do |status|
      assert_no_difference 'DmsfFileRevision.count' do
        post_callback(status: status)
      end
      assert_callback_error 0
    end
  end

  def test_document_server_errors_are_reported
    [3, 7].each do |status|
      post_callback(status: status)
      assert_callback_error 1
    end
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
    assert_equal original_values, saved.custom_field_values.to_h { |value| [value.custom_field_id, value.value] }
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

  def test_view_only_session_cannot_save
    assert_no_difference 'DmsfFileRevision.count' do
      post_callback(status: 2, token: storage_token('callback', mode: 'view'))
    end
    assert_callback_error 1
  end

  def test_callback_rechecks_file_locks
    DmsfFile.any_instance.stubs(:locked_for_user?).returns(true)
    assert_no_difference 'DmsfFileRevision.count' do
      post_callback(status: 2)
    end
    assert_callback_error 1
  end

  def test_callback_rechecks_the_editing_users_permissions
    @role_manager.remove_permission! :file_manipulation
    assert_no_difference 'DmsfFileRevision.count' do
      post_callback(status: 2)
    end
    assert_callback_error 1
  end

  def test_callback_rejects_a_stale_source_revision
    newer = @revision.clone
    newer.user = @jsmith
    newer.save!
    stub_edited_document

    assert_no_difference 'DmsfFileRevision.count' do
      post_callback(status: 2)
    end
    assert_callback_error 1
    assert_nil DmsfFileRevision.find_by(onlyoffice_key: @key)
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

  def storage_token(purpose, mode: 'edit')
    RedmineDmsf::OnlyOffice.storage_token(
      file: @file1, revision: @revision, user: @jsmith, purpose: purpose, key: @key, mode: mode
    )
  end

  def post_callback(status:, token: @callback_token, key: @key)
    payload = { key: key, status: status, url: 'https://office.example.test/cache/edited.txt' }
    jwt = RedmineDmsf::OnlyOffice.jwt_encode(payload, 'onlyoffice-test-secret')
    post "/dmsf/onlyoffice/callback?token=#{token}",
         params: { token: jwt }.to_json, headers: { 'CONTENT_TYPE' => 'application/json' }
  end

  def assert_callback_error(expected)
    assert_response :success
    assert_equal expected, JSON.parse(response.body).fetch('error')
  end

  def stub_edited_document
    tempfile = Tempfile.new(['dmsf-onlyoffice-test-', '.txt'])
    @tempfiles << tempfile
    tempfile.write('Edited by ONLYOFFICE')
    tempfile.rewind
    RedmineDmsf::OnlyOffice.stubs(:download_to_tempfile).returns(tempfile)
  end
end
