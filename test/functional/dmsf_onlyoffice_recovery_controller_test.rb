# frozen_string_literal: true

# Redmine plugin for Document Management System "Features"
#
# Karel Pičman <karel.picman@kontron.com>
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
require 'stringio'

# Explicit recovery must not bypass file permissions or overwrite newer work.
class DmsfOnlyofficeRecoveryControllerTest < RedmineDmsf::Test::TestCase
  def setup
    super
    @revision = @file1.last_revision
    RedmineDmsf.stubs(:onlyoffice_document_server_url).returns('https://office.example.test')
    RedmineDmsf.stubs(:onlyoffice_version_constant).returns(DmsfFileRevision::MINOR_VERSION)
    Redmine::Hook.stubs(:call_hook).returns([])
    DmsfMailer.stubs(:deliver_files_updated)
    @session = DmsfOnlyofficeSession.register!(file: @file1, revision: @revision, user: @jsmith,
                                               mode: 'edit', document_key: 'explicit-recovery-session')
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
  end

  def teardown
    User.current = nil
    super
  end

  def test_view_permission_alone_cannot_download_a_recovery_copy
    recovery = store_recovery
    @role_manager.remove_permission! :file_manipulation

    get "/dmsf/files/#{@file1.id}/onlyoffice/recovery/#{recovery.id}/download"

    assert_response :forbidden
  end

  def test_a_recovery_id_cannot_be_accessed_through_another_document
    other_session = DmsfOnlyofficeSession.register!(file: @file2, revision: @file2.last_revision, user: @admin,
                                                    mode: 'edit', document_key: 'other-file-recovery-session')
    recovery = DmsfOnlyofficeRecovery.store!(session: other_session, kind: 'snapshot', io: StringIO.new('Other file'),
                                             filename: 'other.txt', content_type: 'text/plain')

    get "/dmsf/files/#{@file1.id}/onlyoffice/recovery/#{recovery.id}/download"

    assert_response :not_found
  end

  def test_submitted_forms_cannot_overwrite_their_template
    recovery = store_recovery(kind: 'form')
    original = @revision.file.download

    assert_no_difference 'DmsfFileRevision.count' do
      post "/dmsf/files/#{@file1.id}/onlyoffice/recovery/#{recovery.id}/restore",
           params: { expected_revision_id: @revision.id }
    end

    assert_redirected_to "/dmsf/files/#{@file1.id}/onlyoffice/recovery"
    assert flash[:error].present?
    assert_equal original, @revision.reload.file.download
    assert_nil recovery.reload.restored_revision_id
  end

  def test_stale_restore_does_not_overwrite_another_authors_newer_revision
    recovery = store_recovery
    newer = @revision.clone
    newer.user = @admin
    newer.reset_workflow
    newer.minor_version = 1
    newer.save!

    assert_no_difference 'DmsfFileRevision.count' do
      post "/dmsf/files/#{@file1.id}/onlyoffice/recovery/#{recovery.id}/restore",
           params: { expected_revision_id: @revision.id }
    end

    assert_redirected_to "/dmsf/files/#{@file1.id}/onlyoffice/recovery"
    assert flash[:error].present?
    assert_equal newer.id, @file1.dmsf_file_revisions.visible.first.id
    assert_nil recovery.reload.restored_revision_id
    assert_equal 'Recovered work', recovery.payload.download
  end

  def test_forgotten_from_a_fill_session_cannot_overwrite_its_template
    @session.update!(mode: 'fill')
    recovery = store_recovery(kind: 'forgotten')
    assert_no_difference 'DmsfFileRevision.count' do
      post "/dmsf/files/#{@file1.id}/onlyoffice/recovery/#{recovery.id}/restore",
           params: { expected_revision_id: @revision.id }
    end
    assert flash[:error].present?
    assert_nil recovery.reload.restored_revision_id
    assert_equal @revision.id, @file1.reload.last_revision.id
  end

  def test_forgotten_after_a_form_submission_cannot_overwrite_its_template
    store_recovery(kind: 'form')
    recovery = store_recovery(kind: 'forgotten')
    assert_no_difference 'DmsfFileRevision.count' do
      post "/dmsf/files/#{@file1.id}/onlyoffice/recovery/#{recovery.id}/restore",
           params: { expected_revision_id: @revision.id }
    end
    assert flash[:error].present?
    assert_nil recovery.reload.restored_revision_id
  end

  def test_forgotten_from_a_fill_session_can_be_saved_as_an_independent_document
    @session.update!(mode: 'fill')
    recovery = store_recovery(kind: 'forgotten')
    assert_difference 'DmsfFile.count', 1 do
      post "/dmsf/files/#{@file1.id}/onlyoffice/recovery/#{recovery.id}/copy",
           params: { title: 'Independent filled form' }
    end
    assert_equal @revision.id, @file1.reload.last_revision.id
    assert_not_equal @file1.id, recovery.reload.restored_revision.dmsf_file_id
  end

  def test_restore_retry_creates_only_one_revision_and_keeps_the_original_bytes
    recovery = store_recovery
    original = @revision.file.download
    path = "/dmsf/files/#{@file1.id}/onlyoffice/recovery/#{recovery.id}/restore"

    assert_difference 'DmsfFileRevision.count', 1 do
      post path, params: { expected_revision_id: @revision.id }
    end
    assert_redirected_to "/dmsf/files/#{@file1.id}"
    restored_id = recovery.reload.restored_revision_id
    assert restored_id

    assert_no_difference 'DmsfFileRevision.count' do
      post path, params: { expected_revision_id: @revision.id }
    end

    assert_redirected_to "/dmsf/files/#{@file1.id}"
    assert_equal restored_id, recovery.reload.restored_revision_id
    assert_equal 'Recovered work', DmsfFileRevision.find(restored_id).file.download
    assert_equal original, @revision.reload.file.download
  end

  def test_save_copy_retry_returns_the_same_independent_document
    recovery = store_recovery
    path = "/dmsf/files/#{@file1.id}/onlyoffice/recovery/#{recovery.id}/copy"

    assert_difference 'DmsfFile.count', 1 do
      post path, params: { title: 'Recovered independent copy' }
    end
    restored = DmsfFileRevision.find(recovery.reload.restored_revision_id)
    assert_not_equal @file1.id, restored.dmsf_file_id

    assert_no_difference ['DmsfFile.count', 'DmsfFileRevision.count'] do
      post path, params: { title: 'Ignored duplicate request title' }
    end

    assert_redirected_to "/dmsf/files/#{restored.dmsf_file_id}"
    assert_equal 'Recovered work', restored.file.download
  end

  def test_form_import_does_not_accept_unmapped_issue_attributes
    issue = Issue.find(1)
    original = issue.attributes.slice('subject', 'status_id', 'lock_version')
    recovery = store_recovery(kind: 'form', metadata: {
                                'forms_data' => [{ 'key' => 'subject', 'value' => 'Unapproved replacement' }]
                              })
    RedmineDmsf.stubs(:onlyoffice_form_field_mapping).returns({})

    assert_no_difference 'Journal.count' do
      post "/dmsf/files/#{@file1.id}/onlyoffice/recovery/#{recovery.id}/form",
           params: { issue_id: issue.id, lock_version: issue.lock_version,
                     issue: { subject: 'Unapproved replacement', status_id: 5 } }
    end

    assert_redirected_to "/dmsf/files/#{@file1.id}/onlyoffice/recovery"
    assert flash[:error].present?
    assert_equal original, issue.reload.attributes.slice('subject', 'status_id', 'lock_version')
  end

  private

  def store_recovery(kind: 'snapshot', metadata: {})
    DmsfOnlyofficeRecovery.store!(session: @session, kind: kind, io: StringIO.new('Recovered work'),
                                  filename: 'test.txt', content_type: 'text/plain', metadata: metadata)
  end
end
