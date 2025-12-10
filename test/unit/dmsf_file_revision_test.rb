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

require File.expand_path('../../test_helper', __FILE__)

# File revision tests
class DmsfFileRevisionTest < RedmineDmsf::Test::UnitTest
  include Redmine::I18n

  def setup
    super
    @revision1 = DmsfFileRevision.find 1
    @revision2 = DmsfFileRevision.find 2
    @revision3 = DmsfFileRevision.find 3
    @revision7 = DmsfFileRevision.find 7
    @revision8 = DmsfFileRevision.find 8
    @revision13 = DmsfFileRevision.find 13
    @wf1 = DmsfWorkflow.find 1
  end

  def test_name_presence
    @revision1.name = ''
    assert @revision1.invalid?
    assert_includes @revision1.errors.full_messages, 'Name cannot be blank'
  end

  def test_title_presence
    @revision1.title = ''
    assert @revision1.invalid?
    assert_includes @revision1.errors.full_messages, 'Title cannot be blank'
  end

  def test_title_length_validation
    @revision1.title = String.new('a' * 256)
    assert @revision1.invalid?
    assert_includes @revision1.errors.full_messages, 'Title is too long (maximum is 255 characters)'
  end

  def test_name_length_validation
    @revision1.name = String.new('a' * 256)
    assert @revision1.invalid?
    assert_includes @revision1.errors.full_messages, 'Name is too long (maximum is 255 characters)'
  end

  def test_name_invalid_characters_validation
    @revision1.name << DmsfFolder::INVALID_CHARACTERS[0]
    assert @revision1.invalid?
    assert_includes @revision1.errors.full_messages,
                    "Name #{l('activerecord.errors.messages.error_contains_invalid_character')}"
  end

  def test_title_invalid_characters_validation
    @revision1.title << DmsfFolder::INVALID_CHARACTERS[0]
    assert @revision1.invalid?
    assert_includes @revision1.errors.full_messages,
                    "Title #{l('activerecord.errors.messages.error_contains_invalid_character')}"
  end

  def test_delete_restore
    @revision13.delete commit: false
    assert @revision13.deleted?, "File revision #{@revision13.name} hasn't been deleted"
    @revision13.restore
    assert_not @revision13.deleted?, "File revision #{@revision13.name} hasn't been restored"
  end

  def test_destroy
    @revision13.delete commit: true
    assert_nil DmsfFileRevision.find_by(id: @revision13.id)
  end

  def test_invalid_filename_extension
    with_settings(attachment_extensions_allowed: 'txt') do
      r1 = DmsfFileRevision.new
      r1.minor_version = 0
      r1.major_version = 1
      r1.dmsf_file = @file1 # name test.txt
      r1.user = User.current
      r1.name = 'test.txt.png'
      r1.title = File.basename(r1.name, '.*')
      r1.description = nil
      r1.comment = nil
      r1.size = 4
      assert r1.invalid?
      message = ['Attachment extension .png is not allowed']
      assert_equal message, r1.errors.full_messages
    end
  end

  def test_workflow_tooltip
    @revision2.set_workflow @wf1.id, 'start'
    assert_equal @jsmith.name, @revision2.workflow_tooltip
  end

  def test_version
    @revision1.major_version = 1
    @revision1.minor_version = 0
    assert_equal '1.0', @revision1.version
    @revision1.major_version = -'A'.ord
    @revision1.minor_version = -' '.ord
    assert_equal 'A', @revision1.version
    @revision1.major_version = -'A'.ord
    @revision1.minor_version = 0
    assert_equal 'A.0', @revision1.version
  end

  def test_increase_version
    # 1.0.0 -> 1.0.1
    @revision1.major_version = 1
    @revision1.minor_version = 0
    @revision1.increase_version DmsfFileRevision::PATCH_VERSION
    assert_equal 1, @revision1.major_version
    assert_equal 0, @revision1.minor_version
    assert_equal 1, @revision1.patch_version
    # 1.0 -> 1.1
    @revision1.major_version = 1
    @revision1.minor_version = 0
    @revision1.increase_version DmsfFileRevision::MINOR_VERSION
    assert_equal 1, @revision1.major_version
    assert_equal 1, @revision1.minor_version
    # 1.0 -> 2.0
    @revision1.major_version = 1
    @revision1.minor_version = 0
    @revision1.increase_version DmsfFileRevision::MAJOR_VERSION
    assert_equal 2, @revision1.major_version
    assert_equal 0, @revision1.minor_version
    # 1.1 -> 2.0
    @revision1.major_version = 1
    @revision1.minor_version = 1
    @revision1.increase_version DmsfFileRevision::MAJOR_VERSION
    assert_equal 2, @revision1.major_version
    assert_equal 0, @revision1.minor_version
    # A -> A.1
    @revision1.major_version = -'A'.ord
    @revision1.minor_version = -' '.ord
    @revision1.increase_version DmsfFileRevision::MINOR_VERSION
    assert_equal(-'A'.ord, @revision1.major_version)
    assert_equal 1, @revision1.minor_version
    # A -> B
    @revision1.major_version = -'A'.ord
    @revision1.minor_version = -' '.ord
    @revision1.increase_version DmsfFileRevision::MAJOR_VERSION
    assert_equal(-'B'.ord, @revision1.major_version)
    assert_equal(-' '.ord, @revision1.minor_version)
    # A.1 -> B
    @revision1.major_version = -'A'.ord
    @revision1.minor_version = 1
    @revision1.increase_version DmsfFileRevision::MAJOR_VERSION
    assert_equal(-'B'.ord, @revision1.major_version)
    assert_equal(-' '.ord, @revision1.minor_version)
  end

  def test_description_max_length
    @revision1.description = 'a' * 2.kilobytes
    assert_not @revision1.save
    @revision1.description = 'a' * 1.kilobyte
    assert @revision1.save
  end

  def test_protocol_txt
    assert_not @revision1.protocol
  end

  def test_protocol_doc
    @revision1.file.blob.content_type = Redmine::MimeType.of('test.doc')
    assert_equal 'ms-word', @revision1.protocol
  end

  def test_protocol_docx
    @revision1.file.blob.content_type = Redmine::MimeType.of('test.docx')
    assert_equal 'ms-word', @revision1.protocol
  end

  def test_protocol_odt
    @revision1.file.blob.content_type = Redmine::MimeType.of('test.odt')
    assert_equal 'ms-word', @revision1.protocol
  end

  def test_protocol_xls
    @revision1.file.blob.content_type = Redmine::MimeType.of('test.xls')
    assert_equal 'ms-excel', @revision1.protocol
  end

  def test_protocol_xlsx
    @revision1.file.blob.content_type = Redmine::MimeType.of('test.xlsx')
    assert_equal 'ms-excel', @revision1.protocol
  end

  def test_protocol_ods
    @revision1.file.blob.content_type = Redmine::MimeType.of('test.ods')
    assert_equal 'ms-excel', @revision1.protocol
  end

  def test_obsolete
    assert @revision1.obsolete
    assert_equal DmsfWorkflow::STATE_OBSOLETE, @revision1.workflow
  end

  def test_obsolete_locked
    User.current = @admin
    @revision1.dmsf_file.lock!
    User.current = @jsmith
    assert_not @revision1.obsolete
    assert_equal 1, @revision1.errors.count
    assert @revision1.errors.full_messages.to_sentence.include?(l(:error_file_is_locked))
  end

  def test_major_version_cannot_be_nil
    @revision1.major_version = nil
    assert_not @revision1.save
    assert @revision1.errors.full_messages.to_sentence.include?('Major version cannot be blank')
  end

  def test_size_validation
    Setting.attachment_max_size = '1'
    @revision1.size = 2.kilobytes
    assert_not @revision1.valid?
  end

  def test_visible
    @revision1.deleted = DmsfFileRevision::STATUS_ACTIVE
    assert @revision1.visible?
    assert @revision1.visible?(@jsmith)
    @revision1.deleted = DmsfFileRevision::STATUS_DELETED
    assert_not @revision1.visible?
    assert_not @revision1.visible?(@jsmith)
  end

  def test_params_to_hash
    parameters = ActionController::Parameters.new({
                                                    '78': 'A',
                                                    '90': {
                                                      'blank': '',
                                                      '1': {
                                                        'filename': 'file.txt',
                                                        'token': 'atoken'
                                                      }
                                                    }
                                                  })
    h = DmsfFileRevision.params_to_hash(parameters)
    assert h.is_a?(Hash)
    assert_equal 'atoken', h['90'][:token]
  end

  def test_params_to_hash_empty_attachment
    parameters = ActionController::Parameters.new({
                                                    '78': 'A',
                                                    '90': {
                                                      'blank': '',
                                                      '1': {
                                                        'file': ''
                                                      }
                                                    }
                                                  })
    h = DmsfFileRevision.params_to_hash(parameters)
    assert h.is_a?(Hash)
    assert_nil h['90']
  end

  def test_set_workflow
    @revision2.set_workflow @wf1.id, 'assign'
    assert_equal DmsfWorkflow::STATE_ASSIGNED, @revision2.workflow
    assert_equal User.current, @revision2.dmsf_workflow_assigned_by_user
    assert @revision2.dmsf_workflow_assigned_at
    @revision2.set_workflow @wf1.id, 'start'
    assert_equal DmsfWorkflow::STATE_WAITING_FOR_APPROVAL, @revision2.workflow
    assert_equal User.current, @revision2.dmsf_workflow_started_by_user
    assert @revision2.dmsf_workflow_started_at
  end

  def test_reset_workflow
    @revision2.set_workflow @wf1.id, 'assign'
    @revision2.set_workflow @wf1.id, 'start'
    @revision2.reset_workflow
    assert_nil @revision2.workflow
    assert_nil @revision2.dmsf_workflow_id
    assert_nil @revision2.dmsf_workflow_assigned_by_user_id
    assert_nil @revision2.dmsf_workflow_assigned_at
    assert_nil @revision2.dmsf_workflow_started_by_user_id
    assert_nil @revision2.dmsf_workflow_started_at
  end

  def test_checksum
    assert_equal @revision1.checksum, @revision1.file.blob.checksum
  end

  def test_content_type
    assert_equal 'text/plain', @revision1.content_type
    @revision1.file.blob.content_type = ''
    assert_equal 'text/plain', @revision1.content_type
    @revision1.file.blob.filename = 'data'
    assert_equal 'application/octet-stream', @revision1.content_type
  end
end
