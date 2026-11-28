# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)
require 'stringio'
require 'uri'

# Security and retention behavior of the editor's authenticated history bridge.
class DmsfOnlyofficeHistoryControllerTest < RedmineDmsf::Test::TestCase
  def setup
    super
    @revision = @file1.last_revision
    @role_manager.add_permission! :view_dmsf_file_revisions
    RedmineDmsf.stubs(:onlyoffice_document_server_url).returns('https://office.example.test')
    RedmineDmsf.stubs(:onlyoffice_document_server_internal_url).returns('')
    RedmineDmsf.stubs(:onlyoffice_redmine_internal_url).returns('')
    RedmineDmsf.stubs(:onlyoffice_jwt_secret).returns('onlyoffice-test-secret')
    RedmineDmsf.stubs(:onlyoffice_jwt_algorithm).returns('HS256')
    RedmineDmsf.stubs(:onlyoffice_token_ttl).returns(3600)
    RedmineDmsf.stubs(:onlyoffice_editable_extensions).returns(%w[txt docx])
    RedmineDmsf.stubs(:onlyoffice_version_constant).returns(DmsfFileRevision::MINOR_VERSION)
    DmsfMailer.stubs(:deliver_files_updated)
  end

  def teardown
    User.current = nil
    super
  end

  def test_history_requires_the_distinct_revision_permission
    @role_manager.remove_permission! :view_dmsf_file_revisions
    login
    get history_path
    assert_response :forbidden
  end

  def test_editor_does_not_offer_history_without_the_revision_permission
    @role_manager.remove_permission! :view_dmsf_file_revisions
    login
    get "/dmsf/files/#{@file1.id}/onlyoffice/view"
    assert_response :success
    assert_select 'button[data-office-action="history"]', count: 0
    assert_select 'button[data-office-action="compare"]', count: 0
  end

  def test_history_is_limited_to_retained_revisions_of_the_document
    deleted = copy_revision(@revision)
    deleted.update!(deleted: DmsfFileRevision::STATUS_DELETED)
    login
    get history_path
    assert_response :success
    ids = json.fetch('history').map { |entry| entry.fetch('version') }
    assert_includes ids, @revision.id
    assert_not_includes ids, deleted.id
    assert_not_includes ids, @file2.last_revision.id
  end

  def test_old_revisions_without_history_metadata_are_signed_snapshots
    login
    get history_data_path, params: { revision_id: @revision.id }
    assert_response :success
    data = json
    assert_equal @revision.id, data.fetch('version')
    assert_nil data['changesUrl']
    assert_nil data['previous']
    signed = RedmineDmsf::OnlyOffice.jwt_decode(data.fetch('token'), 'onlyoffice-test-secret')
    assert_equal data.fetch('url'), signed.fetch('url')
    assert_equal 'history_document', document_claims(data.fetch('url')).fetch('purpose')
  end

  def test_saved_change_archive_and_its_exact_source_are_used
    newer = copy_revision(@revision)
    store_history(newer, @revision)
    login
    get history_data_path, params: { revision_id: newer.id }
    assert_response :success
    data = json
    assert_equal @revision.id, document_claims(data.fetch('previous').fetch('url')).fetch('revision_id')
    assert_includes data.fetch('changesUrl'), 'kind=changes'
    get history_path
    entry = json.fetch('history').find { |row| row['version'] == newer.id }
    assert_equal '9.0.0', entry.fetch('serverVersion')
    assert_equal 'change-author', entry.fetch('changes').first.fetch('user').fetch('id')
  end

  def test_pruning_the_original_source_falls_back_to_a_snapshot
    newer = copy_revision(@revision)
    store_history(newer, @revision)
    @revision.update!(deleted: DmsfFileRevision::STATUS_DELETED)
    login
    get history_data_path, params: { revision_id: newer.id }
    assert_response :success
    assert_nil json['previous']
    assert_nil json['changesUrl']
    get history_path
    entry = json.fetch('history').find { |row| row['version'] == newer.id }
    assert_nil entry['changes']
    assert_nil entry['serverVersion']
  end

  def test_incomplete_change_metadata_falls_back_to_a_snapshot
    newer = copy_revision(@revision)
    record = store_history(newer, @revision)
    record.update!(metadata: { 'changes' => [{ 'user' => { 'id' => '2' } }] })
    login
    get history_data_path, params: { revision_id: newer.id }
    assert_response :success
    assert_nil json['previous']
    assert_nil json['changesUrl']
    get history_path
    entry = json.fetch('history').find { |row| row['version'] == newer.id }
    assert_nil entry['changes']
    assert_nil entry['serverVersion']
  end

  def test_history_data_does_not_accept_another_documents_revision
    login
    get history_data_path, params: { revision_id: @file2.last_revision.id }
    assert_response :not_found
  end

  def test_signed_history_documents_work_without_a_browser_login
    with_settings login_required: '1' do
      get asset_path, params: { kind: 'document', token: history_token(@revision, 'history_document') }
      assert_response :success
      assert_equal @revision.file.download, response.body
      assert_equal 'https://office.example.test', response.headers['Access-Control-Allow-Origin']
    end
  end

  def test_history_tokens_cannot_be_reused_for_a_different_asset_kind_or_file
    token = history_token(@revision, 'history_document')
    get asset_path, params: { kind: 'changes', token: token }
    assert_response :not_found
    get "/dmsf/files/#{@file2.id}/onlyoffice/history/asset", params: { kind: 'document', token: token }
    assert_response :not_found
    get asset_path, params: { kind: 'document', token: history_token(@revision, 'download') }
    assert_response :not_found
  end

  def test_signed_history_download_rechecks_revoked_revision_permissions
    token = history_token(@revision, 'history_document')
    @role_manager.remove_permission! :view_dmsf_file_revisions
    get asset_path, params: { kind: 'document', token: token }
    assert_response :not_found
  end

  def test_signed_history_download_rechecks_folder_permissions
    token = history_token(@revision, 'history_document')
    DmsfFolder.stubs(:permissions?).returns(false)
    get asset_path, params: { kind: 'document', token: token }
    assert_response :not_found
  end

  def test_change_archive_is_not_served_after_its_source_is_pruned
    newer = copy_revision(@revision)
    store_history(newer, @revision)
    token = history_token(newer, 'history')
    get asset_path, params: { kind: 'changes', token: token }
    assert_response :success
    @revision.update!(deleted: DmsfFileRevision::STATUS_DELETED)
    get asset_path, params: { kind: 'changes', token: token }
    assert_response :not_found
  end

  def test_restore_creates_a_new_revision_without_overwriting_retained_content
    original_bytes = @revision.file.download
    head = copy_revision(@revision)
    head.minor_version = (head.minor_version || 0) + 5
    head.save!
    login
    assert_difference 'DmsfFileRevision.count', 1 do
      post restore_path, params: { revision_id: @revision.id, expected_revision_id: head.id }
    end
    assert_response :success
    restored = DmsfFileRevision.find(json.fetch('revision_id'))
    assert_equal @revision.id, restored.source_dmsf_file_revision_id
    assert_equal original_bytes, restored.file.download
    assert_equal original_bytes, @revision.reload.file.download
    assert_operator restored.minor_version, :>, head.minor_version
    assert_nil restored.workflow
  end

  def test_restore_rejects_a_stale_expected_head
    copy_revision(@revision)
    login
    assert_no_difference 'DmsfFileRevision.count' do
      post restore_path, params: { revision_id: @revision.id, expected_revision_id: @revision.id }
    end
    assert_response :conflict
  end

  def test_restore_requires_an_explicit_expected_head
    login
    assert_no_difference 'DmsfFileRevision.count' do
      post restore_path, params: { revision_id: @revision.id }
    end
    assert_response :unprocessable_entity
  end

  def test_restore_requires_write_access_and_an_unlocked_file
    @role_manager.remove_permission! :file_manipulation
    login
    assert_no_difference 'DmsfFileRevision.count' do
      post restore_path, params: { revision_id: @revision.id, expected_revision_id: @revision.id }
    end
    assert_response :forbidden
    @role_manager.add_permission! :file_manipulation
    DmsfFile.any_instance.stubs(:locked_for_user?).returns(true)
    assert_no_difference 'DmsfFileRevision.count' do
      post restore_path, params: { revision_id: @revision.id, expected_revision_id: @revision.id }
    end
    assert_response :forbidden
  end

  def test_comparison_only_returns_permitted_revisions_and_signed_payloads
    comparable = copy_revision(@revision)
    comparable.update!(name: 'comparison.docx')
    login
    get compare_path, params: { c: 'compare' }
    assert_response :success
    item = json.fetch('revisions').find { |row| row['id'] == comparable.id }
    assert item
    payload = item.fetch('request')
    signed = RedmineDmsf::OnlyOffice.jwt_decode(payload.fetch('token'), 'onlyoffice-test-secret')
    assert_equal 'compare', signed.fetch('c')
    assert_equal 'docx', signed.fetch('fileType')
    assert_equal payload.fetch('url'), signed.fetch('url')
  end

  def test_comparison_rejects_a_document_in_a_different_project
    foreign = DmsfFile.visible.where.not(project_id: @file1.project_id).first
    assert foreign
    login
    get compare_path, params: { file_id: foreign.id }
    assert_response :not_found
  end

  private

  def login
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
  end

  def json
    JSON.parse(response.body)
  end

  def history_path
    "/dmsf/files/#{@file1.id}/onlyoffice/history"
  end

  def history_data_path
    "#{history_path}/data"
  end

  def asset_path
    "#{history_path}/asset"
  end

  def restore_path
    "/dmsf/files/#{@file1.id}/onlyoffice/restore"
  end

  def compare_path
    "/dmsf/files/#{@file1.id}/onlyoffice/compare"
  end

  def copy_revision(source)
    revision = source.clone
    revision.user = @jsmith
    revision.shared_file.attach(source.file.blob)
    revision.save!
    revision
  end

  def store_history(revision, source)
    DmsfOnlyofficeHistory.store!(
      revision: revision, source: source,
      metadata: { 'changes' => [{ 'user' => { 'id' => 'change-author', 'name' => 'Collaborator' } }],
                  'serverVersion' => '9.0.0' },
      io: StringIO.new('test change archive')
    )
  end

  def history_token(revision, purpose)
    RedmineDmsf::OnlyOffice.storage_token(file: @file1, revision: revision, user: @jsmith, purpose: purpose)
  end

  def document_claims(url)
    token = URI.decode_www_form(URI.parse(url).query).to_h.fetch('token')
    RedmineDmsf::OnlyOffice.decode_storage_token(token, purpose: 'history_document')
  end
end
