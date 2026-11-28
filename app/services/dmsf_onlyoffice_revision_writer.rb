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

# Shared publication path for callbacks, restored revisions and recovered files.
class DmsfOnlyofficeRevisionWriter
  class Conflict < RedmineDmsf::OnlyOffice::Error; end
  class PermissionDenied < RedmineDmsf::OnlyOffice::Error; end

  # ActiveRecord runs this record after the outermost transaction commits, even
  # when the caller wraps publication and its own audit records in a transaction.
  class Notification
    def initialize(file_id, user)
      @file_id = file_id
      @user = user
    end

    def trigger_transactional_callbacks?
      false
    end

    def before_committed!(*); end
    def rolledback!(*); end

    def committed!(*, **)
      file = DmsfFile.find_by(id: @file_id)
      return unless file

      DmsfOnlyofficeSession.with_user(@user) { DmsfMailer.deliver_files_updated(file.project, [file]) }
    rescue StandardError => e
      Rails.logger.error "Could not send ONLYOFFICE update notifications: #{e.message}"
    end
  end

  def self.call(file:, source:, user:, expected_revision_id:, io: nil, filename: nil, content_type: nil, comment: nil,
                key: nil, major: false, permission: :file_manipulation)
    new.call(file: file, source: source, user: user, io: io, filename: filename, content_type: content_type,
             comment: comment, key: key, expected_revision_id: expected_revision_id, major: major,
             permission: permission)
  end

  def call(file:, source:, user:, io:, filename:, content_type:, comment:, key:, expected_revision_id:, major:,
           permission:)
    DmsfOnlyofficeSession.with_user(user) do
      revision = nil
      DmsfFile.transaction do
        file = DmsfFile.lock.find(file.id)
        check_permission!(file, user, permission)
        existing = DmsfFileRevision.find_by(onlyoffice_key: key) if key.present?
        if existing
          raise Conflict, 'The publication key belongs to another document' unless existing.dmsf_file_id == file.id

          revision = existing
          next
        end

        current = file.dmsf_file_revisions.visible.first
        unless current && current.id == expected_revision_id.to_i
          raise Conflict, 'A newer DMSF revision was created while the document was open'
        end

        begin
          source&.reload
        rescue ActiveRecord::RecordNotFound
          raise Conflict, 'The source revision is no longer available'
        end
        unless source && source.dmsf_file_id == file.id && source.visible?
          raise Conflict, 'The source revision is no longer available'
        end
        raise PermissionDenied, 'The DMSF file is locked by another user' if file.locked_for_user?

        revision = source.clone
        revision.dmsf_file = file
        revision.user = user
        revision.source_revision = source
        revision.onlyoffice_key = key
        revision.comment = comment || I18n.with_locale(user.language.presence || I18n.default_locale) do
          I18n.t(:comment_dmsf_onlyoffice_revision)
        end
        revision.reset_workflow
        # Historical restores copy their content and metadata, but advance from
        # the current head's version rather than reusing an old version number.
        revision.major_version = current.major_version
        revision.minor_version = current.minor_version
        revision.patch_version = current.patch_version
        increase_version(revision, major ? DmsfFileRevision::MAJOR_VERSION : RedmineDmsf.onlyoffice_version_constant)
        revision.name = filename.presence || source.name
        raise Conflict, 'Invalid document filename' unless File.basename(revision.name) == revision.name

        attach_content(revision, source, io, content_type)
        values = source.custom_field_values.to_h { |value| [value.custom_field_id.to_s, value.value] }
        revision.copy_custom_field_values(ActionController::Parameters.new(values), source)
        revision.save!
        file.last_revision = revision
        file.save!
        file.class.connection.add_transaction_record(Notification.new(file.id, user))
      end
      revision
    end
  rescue ActiveRecord::RecordNotUnique
    existing = DmsfFileRevision.find_by(onlyoffice_key: key) if key.present?
    raise unless existing && existing.dmsf_file_id == file.id

    existing
  end

  private

  def check_permission!(file, user, permission)
    mode = DmsfOnlyofficeSession::MODE_PERMISSIONS.key(permission.to_sym)
    return if mode && DmsfOnlyofficeSession.allowed_mode?(file: file, user: user, mode: mode)

    raise PermissionDenied, 'The user is no longer allowed to publish this document'
  end

  def increase_version(revision, component)
    if component == DmsfFileRevision::PATCH_VERSION && revision.minor_version.nil?
      revision.minor_version = 0
      revision.increase_version(component)
    elsif component == DmsfFileRevision::MINOR_VERSION && revision.minor_version.nil?
      revision.minor_version = 1
      revision.patch_version = nil
    else
      revision.increase_version(component)
    end
  end

  def attach_content(revision, source, io, content_type)
    if io.is_a?(ActiveStorage::Blob)
      revision.size = io.byte_size
      revision.shared_file.attach(io)
    elsif io
      io.rewind
      blob = DmsfOnlyofficeBlob.upload!(io: io, filename: revision.name,
                                        content_type: content_type || source.content_type, identify: false)
      revision.size = blob.byte_size
      revision.shared_file.attach(blob)
    else
      raise Conflict, 'The source document bytes are unavailable' unless source.file.attached?

      revision.size = source.file.blob.byte_size
      revision.shared_file.attach(source.file.blob)
    end
  end
end
