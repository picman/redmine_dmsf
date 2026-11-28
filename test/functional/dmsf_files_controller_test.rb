# frozen_string_literal: true

# Redmine plugin for Document Management System "Features"
#
# Copyright © 2011-23 Karel Pičman <karel.picman@kontron.com>
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

require File.expand_path('../../test_helper', __FILE__)
require 'tempfile'

# DmsfFiles controller
class DmsfFilesControllerTest < RedmineDmsf::Test::TestCase
  def teardown
    super
    DmsfFile.clear_previews
  end

  def test_show_file_ok
    # Permissions OK
    RedmineDmsf.stubs(:onlyoffice_document_server_url).returns('https://office.example.test')
    RedmineDmsf.stubs(:onlyoffice_editable_extensions).returns(%w[txt docx])
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    get "/dmsf/files/#{@file1.id}", params: { id: @file1.id }
    assert_response :success
    assert_select 'a.dmsf-onlyoffice-read[href^=?]', dmsf_onlyoffice_view_path(@file1), count: 1
    assert_select 'a.dmsf-onlyoffice-edit[href^=?]', dmsf_onlyoffice_edit_path(@file1), count: 1
  end

  def test_show_formatting_html
    Setting.text_formatting = 'HTML'
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    get "/dmsf/files/#{@file1.id}", params: { id: @file1.id }
    assert_response :success
    assert_include 'dmsf-description', response.body, 'dmsf-description class not found'
    assert_include 'wiki-edit', response.body, 'wiki-edit class not found'
  end

  def test_show_formatting_textile
    Setting.text_formatting = 'Textile'
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    get "/dmsf/files/#{@file1.id}", params: { id: @file1.id }
    assert_response :success
    assert_include 'dmsf-description', response.body, 'dmsf-description class not found'
    assert_include 'wiki-edit', response.body, 'wiki-edit class not found'
  end

  def test_show_file_forbidden
    # Missing permissions
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    @role_manager.remove_permission! :view_dmsf_files
    get "/dmsf/files/#{@file1.id}", params: { id: @file1.id }
    assert_response :forbidden
  end

  def test_view_file_standard_url
    # Permissions OK
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    get "/dmsf/files/#{@file1.id}/view", params: { id: @file1.id }
    assert_response :success
  end

  def test_view_file_pretty_url
    # Permissions OK
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    get "/dmsf/files/#{@file1.id}/test.txt", params: { id: @file1.id }
    assert_response :success
  end

  def test_view_file_forbidden
    # Missing permissions
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    @role_manager.remove_permission! :view_dmsf_files
    get "/dmsf/files/#{@file1.id}/view", params: { id: @file1.id }
    assert_response :forbidden
  end

  def test_historical_download_requires_history_permission
    original = @file1.last_revision
    newer = original.clone
    newer.user = @admin
    newer.minor_version += 1
    newer.save!
    @role_manager.remove_permission! :view_dmsf_file_revisions
    post '/login', params: { username: 'jsmith', password: 'jsmith' }

    get "/dmsf/files/#{@file1.id}/view", params: { download: original.id }
    assert_response :forbidden
    get "/dmsf/files/#{@file1.id}/view", params: { download: newer.id }
    assert_response :success
  end

  def test_deleted_revision_cannot_be_downloaded_by_id
    original = @file1.last_revision
    newer = original.clone
    newer.user = @admin
    newer.minor_version += 1
    newer.save!
    original.update!(deleted: DmsfFileRevision::STATUS_DELETED)
    post '/login', params: { username: 'admin', password: 'admin' }

    get "/dmsf/files/#{@file1.id}/view", params: { download: original.id }
    assert_response :not_found
  end

  def test_view_preview
    return unless RedmineDmsf::Preview.office_available?

    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    get "/dmsf/files/#{@file13.id}/view", params: { id: @file13.id }
    assert_response :success
    assert_equal 'application/pdf', @response.media_type
    assert @response.body.starts_with?('%PDF')
  end

  def delete_forbidden
    # Missing permissions
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    @role_manager.remove_permission! :file_manipulation
    delete "/dmsf/files/#{@file1.id}", params: { id: @file1.id, folder_id: @file1.dmsf_folder.id, commit: false }
    assert_response :forbidden
  end

  def delete_locked
    # Permissions OK but the file is locked
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    delete "/dmsf/files/#{@file2.id}", params: { id: @file2.id, folder_id: @file2.dmsf_folder.id, commit: false }
    assert_response :redirect
    assert_include l(:error_file_is_locked), flash[:error]
  end

  def delete_ok
    # Permissions OK and not locked
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    delete "/dmsf/files/#{@file1.id}", params: { id: @file1.id, folder_id: @file1.dmsf_folder.id, commit: false }
    assert_redirected_to dmsf_folder_path(id: @file1.project, folder_id: @file1.dmsf_folder.id)
  end

  def test_delete_in_subfolder
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    delete "/dmsf/files/#{@file4.id}", params: { id: @file4.id, folder_id: @file4.dmsf_folder.id, commit: false }
    assert_redirected_to dmsf_folder_path(id: @file4.project, folder_id: @file4.dmsf_folder.id)
  end

  def test_obsolete_revision_ok
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    get "/dmsf/files/#{@file1.id}/revision/obsolete", params: { id: @file1.last_revision.id }
    assert_redirected_to action: 'show', id: @file1
  end

  def test_obsolete_revision_missing_permissions
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    @role_manager.remove_permission! :file_manipulation
    get "/dmsf/files/#{@file1.id}/revision/obsolete", params: { id: @file1.last_revision.id }
    assert :forbiden
  end

  def test_create_revision
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    assert_difference 'DmsfFileRevision.count', +1 do
      post "/dmsf/files/#{@file1.id}/revision/create",
           params: {
             id: @file1.id,
             version_major: @file1.last_revision.major_version,
             version_minor: @file1.last_revision.minor_version + 1,
             dmsf_file_revision: {
               title: @file1.title,
               name: @file1.name,
               description: @file1.description,
               comment: 'New revision'
             }
           }
    end
    assert_redirected_to dmsf_folder_path(id: @file1.project)
    assert_not_nil @file1.last_revision.checksum
  end

  def test_create_revision_rejects_a_missing_attachment_token
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    original = @file1.last_revision
    assert_no_difference ['DmsfFileRevision.count', 'ActiveStorage::Blob.count'] do
      post "/dmsf/files/#{@file1.id}/revision/create",
           params: revision_parameters(original).merge(dmsf_attachments: { '0' => { token: 'missing-token' } })
    end
    assert flash[:error].present?
    assert_equal original.id, @file1.reload.last_revision.id
  end

  def test_create_revision_rejects_a_duplicate_version
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    original = @file1.last_revision
    assert_no_difference 'DmsfFileRevision.count' do
      post "/dmsf/files/#{@file1.id}/revision/create",
           params: revision_parameters(original).merge(version_minor: original.minor_version)
    end
    assert flash[:error].present?
    assert_equal original.id, @file1.reload.last_revision.id
  end

  def test_create_revision_storage_failure_preserves_the_temporary_attachment
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    original = @file1.last_revision
    io = Tempfile.new('dmsf-revision-test')
    io.write('replacement')
    io.flush
    attachment = mock
    attachment.stubs(:diskfile).returns(io.path)
    attachment.stubs(:filesize).returns(11)
    attachment.stubs(:filename).returns(original.name)
    attachment.stubs(:content_type).returns('text/plain')
    attachment.expects(:delete_from_disk).never
    attachment.expects(:destroy).never
    Attachment.stubs(:find_by_token).returns(attachment)
    DmsfOnlyofficeBlob.expects(:upload!).raises(IOError, 'storage unavailable')

    assert_no_difference ['DmsfFileRevision.count', 'ActiveStorage::Blob.count'] do
      post "/dmsf/files/#{@file1.id}/revision/create",
           params: revision_parameters(original).merge(dmsf_attachments: { '0' => { token: 'test-token' } })
      assert_response :internal_server_error
    end
    assert_equal original.id, @file1.reload.last_revision.id
  ensure
    io&.close!
  end

  private

  def revision_parameters(revision)
    { version_major: revision.major_version, version_minor: revision.minor_version + 1,
      version_patch: revision.patch_version,
      dmsf_file_revision: { title: revision.title, name: revision.name, comment: 'Atomic revision' } }
  end
end
