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
require 'tempfile'

# A server recovery copy must never be deleted before its exact bytes are retained.
class DmsfOnlyofficeAdminControllerTest < RedmineDmsf::Test::TestCase
  def setup
    super
    @revision = @file1.last_revision
    @tempfiles = []
    RedmineDmsf.stubs(:onlyoffice_document_server_url).returns('https://office.example.test')
    RedmineDmsf.stubs(:onlyoffice_jwt_secret).returns('onlyoffice-test-secret')
    @session = DmsfOnlyofficeSession.register!(file: @file1, revision: @revision, user: @admin,
                                               mode: 'edit', document_key: 'admin-recovery-session')
    @session.update!(state: 'recovery')
    # Document Server presence is queried before any destructive cleanup.
    RedmineDmsf::OnlyOffice.stubs(:command).with('info', key: @session.document_key)
                           .returns('error' => 0, 'key' => @session.document_key, 'users' => [])
    post '/login', params: { username: 'admin', password: 'admin' }
  end

  def teardown
    @tempfiles.each(&:close!)
    User.current = nil
    super
  end

  def test_non_administrator_cannot_query_the_document_server_inventory
    post '/logout'
    post '/login', params: { username: 'jsmith', password: 'jsmith' }
    RedmineDmsf::OnlyOffice.expects(:command).with('getForgottenList').never

    post '/dmsf/onlyoffice/admin/forgotten'

    assert_response :forbidden
  end

  def test_inventory_only_exposes_keys_registered_by_this_redmine_instance
    foreign_key = 'foreign-redmine-sensitive-document-key'
    RedmineDmsf::OnlyOffice.expects(:command).with('getForgottenList')
                           .returns('error' => 0, 'keys' => [@session.document_key, foreign_key])

    post '/dmsf/onlyoffice/admin/forgotten'

    assert_response :success
    assert_includes response.body, @session.document_key
    assert_not_includes response.body, foreign_key
  end

  def test_delete_without_a_local_recovery_receipt_never_calls_delete_forgotten
    RedmineDmsf::OnlyOffice.expects(:command).with('deleteForgotten', key: @session.document_key).never

    post "/dmsf/onlyoffice/admin/forgotten/#{@session.id}/delete"

    assert_redirected_to '/dmsf/onlyoffice/admin'
    assert flash[:error].present?
  end

  def test_an_active_session_cannot_have_its_forgotten_copy_deleted
    store_recovery('Saved receipt')
    @session.update!(state: 'active')
    RedmineDmsf::OnlyOffice.expects(:command).with('getForgotten', key: @session.document_key).never
    RedmineDmsf::OnlyOffice.expects(:command).with('deleteForgotten', key: @session.document_key).never

    post "/dmsf/onlyoffice/admin/forgotten/#{@session.id}/delete"

    assert_redirected_to '/dmsf/onlyoffice/admin'
    assert flash[:error].present?
  end

  def test_importing_forgotten_bytes_does_not_delete_the_remote_copy
    content = 'Work recovered from the Document Server'
    RedmineDmsf::OnlyOffice.expects(:command).with('getForgotten', key: @session.document_key)
                           .returns('error' => 0, 'url' => 'https://office.example.test/cache/forgotten.txt')
    RedmineDmsf::OnlyOffice.expects(:command).with('deleteForgotten', key: @session.document_key).never
    RedmineDmsf::OnlyOffice.stubs(:download_to_tempfile).returns(tempfile(content))

    assert_difference 'DmsfOnlyofficeRecovery.count', 1 do
      post "/dmsf/onlyoffice/admin/forgotten/#{@session.id}/recover"
    end

    assert_redirected_to '/dmsf/onlyoffice/admin'
    recovered = @session.recoveries.find_by!(kind: 'forgotten')
    assert_equal content, recovered.payload.download
    assert_equal Digest::SHA256.hexdigest(content), recovered.checksum
    assert_equal 'pending', recovered.state
  end

  def test_a_changed_remote_copy_cannot_be_deleted_using_an_older_receipt
    store_recovery('Previously recovered contents')
    RedmineDmsf::OnlyOffice.expects(:command).with('getForgotten', key: @session.document_key)
                           .returns('error' => 0, 'url' => 'https://office.example.test/cache/forgotten.txt')
    RedmineDmsf::OnlyOffice.expects(:command).with('deleteForgotten', key: @session.document_key).never
    RedmineDmsf::OnlyOffice.stubs(:download_to_tempfile).returns(tempfile('Newer unrecovered contents'))

    post "/dmsf/onlyoffice/admin/forgotten/#{@session.id}/delete"

    assert_redirected_to '/dmsf/onlyoffice/admin'
    assert flash[:error].present?
  end

  def test_matching_receipt_allows_remote_cleanup_and_preserves_local_bytes
    content = 'Durably recovered document'
    recovery = store_recovery(content)
    RedmineDmsf::OnlyOffice.expects(:command).with('getForgotten', key: @session.document_key)
                           .returns('error' => 0, 'url' => 'https://office.example.test/cache/forgotten.txt')
    RedmineDmsf::OnlyOffice.expects(:command).with('deleteForgotten', key: @session.document_key)
                           .returns('error' => 0, 'key' => @session.document_key)
    RedmineDmsf::OnlyOffice.stubs(:download_to_tempfile).returns(tempfile(content))

    assert_no_difference 'DmsfOnlyofficeRecovery.count' do
      post "/dmsf/onlyoffice/admin/forgotten/#{@session.id}/delete"
    end

    assert_redirected_to '/dmsf/onlyoffice/admin'
    assert flash[:notice].present?
    assert_equal content, recovery.reload.payload.download
  end

  def test_recovery_still_works_when_the_original_revision_is_missing
    @revision.destroy!
    @session.reload
    assert_nil @session.source_revision
    RedmineDmsf::OnlyOffice.expects(:command).with('getForgotten', key: @session.document_key)
                           .returns('error' => 0, 'url' => 'https://office.example.test/cache/forgotten.txt')
    RedmineDmsf::OnlyOffice.stubs(:download_to_tempfile).returns(tempfile('Recoverable after retention'))

    assert_difference 'DmsfOnlyofficeRecovery.count', 1 do
      post "/dmsf/onlyoffice/admin/forgotten/#{@session.id}/recover"
    end

    assert_redirected_to '/dmsf/onlyoffice/admin'
    assert_equal 'Recoverable after retention', @session.recoveries.find_by!(kind: 'forgotten').payload.download
  end

  private

  def store_recovery(content)
    DmsfOnlyofficeRecovery.store!(session: @session, kind: 'forgotten', io: StringIO.new(content),
                                  filename: @revision.name, content_type: @revision.content_type)
  end

  def tempfile(content)
    file = Tempfile.new(['onlyoffice-admin-', '.txt'])
    @tempfiles << file
    file.write(content)
    file.rewind
    file
  end
end
