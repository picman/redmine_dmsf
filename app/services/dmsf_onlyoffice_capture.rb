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

require 'json'

# Acquire bytes durably before deciding whether they may become a new revision.
class DmsfOnlyofficeCapture
  Result = Struct.new(:revision, :recovery, :published, :duplicate, :state, keyword_init: true)
  FORMS_MAX_BYTES = 2.megabytes

  def self.call(session:, payload:, user: :session_owner, mode: nil)
    actor = user == :session_owner ? session.user : user
    new(session: session, payload: payload, user: actor, mode: mode || session.mode).call
  end

  def initialize(session:, payload:, user:, mode:)
    @session = session
    @payload = payload.deep_stringify_keys
    @user = user
    @mode = mode
    @tempfiles = []
  end

  def call
    unless DmsfOnlyofficeSession::MODE_PERMISSIONS.key?(@mode) && !@session.expired?
      raise RedmineDmsf::OnlyOffice::InvalidToken, 'This session cannot acquire edited content'
    end

    status = @payload['status'].to_i
    raise RedmineDmsf::OnlyOffice::Error, 'Unsupported save status' unless [2, 3, 6, 7].include?(status)

    raise RedmineDmsf::OnlyOffice::Error, 'Missing callback file URL' if @payload['url'].blank?

    io = download(@payload['url'])
    filename, content_type, supported = document_format
    kind = if @mode == 'fill' || (status == 6 && @payload['forcesavetype'].to_i == 3)
             'form'
           elsif status == 6
             'snapshot'
           elsif status == 2
             'final'
           else
             'error'
           end
    metadata = @payload.slice('status', 'forcesavetype', 'userdata', 'users', 'filetype')
    metadata['actor_id'] = @user&.id
    metadata['mode'] = @mode
    acquired = @session.with_lock do
      kind = 'form' if status == 2 && (@session.state == 'submitted' || @session.recoveries.exists?(kind: 'form'))
      if kind == 'snapshot' && @session.state == 'saved'
        capture_late_snapshot(io, filename, content_type, metadata)
      else
        DmsfOnlyofficeRecovery.store!(session: @session, kind: kind, io: io,
                                      filename: filename, content_type: content_type, metadata: metadata)
      end
    end
    return acquired if acquired.is_a?(Result)

    recovery = acquired
    capture_forms(recovery) if kind == 'form' && @payload['formsdataurl'].present?

    if [3, 7].include?(status)
      reason = "ONLYOFFICE reported save error status #{status}; the returned bytes were retained"
      recovery.update!(reason: reason)
      @session.record_callback!(next_state: 'recovery', error: reason, closed: status == 3)
      return Result.new(recovery: recovery, published: false, state: @session.state)
    end
    if kind == 'form'
      @session.record_callback!(next_state: 'submitted', closed: status == 2)
      return Result.new(recovery: recovery, published: false, state: @session.state)
    end
    if status == 6
      @session.record_callback!(next_state: 'snapshot')
      return Result.new(recovery: recovery, published: false, state: @session.state)
    end
    unless supported
      reason = 'The returned document format is not supported for publication'
      recovery.update!(reason: reason)
      @session.record_callback!(next_state: 'recovery', error: reason, closed: true)
      return Result.new(recovery: recovery, published: false, state: @session.state)
    end

    publish(recovery)
  rescue StandardError => e
    durably_acquired = recovery&.persisted? && recovery.payload.attached?
    @session.record_callback!(next_state: 'error', error: e.message,
                              closed: [2, 3].include?(status) && durably_acquired)
    raise
  ensure
    @tempfiles.each(&:close!)
  end

  private

  def download(url, max_bytes: nil)
    limit = Setting.attachment_max_size.to_i.kilobytes
    limit = nil unless limit.positive?
    tempfile = RedmineDmsf::OnlyOffice.download_to_tempfile(url, max_bytes: max_bytes || limit)
    @tempfiles << tempfile
    tempfile
  end

  def document_format
    source = @session.source_revision
    original = source&.name.presence || @session.source_filename.presence || 'recovered-document.bin'
    extension = @payload['filetype'].presence || RedmineDmsf::OnlyOffice.extension(original)
    valid_extension = extension.is_a?(String) && extension.match?(/\A[a-zA-Z0-9]{1,16}\z/)
    extension = valid_extension ? extension.downcase : RedmineDmsf::OnlyOffice.extension(original)
    extension = 'bin' if extension.blank?
    stem = File.basename(original, File.extname(original)).each_char.take(254 - extension.length).join
    filename = "#{stem}.#{extension}"
    original_extension = RedmineDmsf::OnlyOffice.extension(original)
    content_type = Redmine::MimeType.of(filename).presence
    content_type ||= @session.source_content_type.presence if extension == original_extension
    content_type ||= 'application/octet-stream'
    [filename, content_type, valid_extension && RedmineDmsf::OnlyOffice::VIEWABLE_EXTENSIONS.include?(extension)]
  end

  def capture_late_snapshot(io, filename, content_type, metadata)
    checksum = DmsfOnlyofficeRecovery.checksum_for(io)
    final = @session.recoveries.find_by(kind: 'final', state: 'imported',
                                        restored_revision_id: @session.saved_revision_id)
    final_checksum = final&.checksum
    if final_checksum.nil? && @session.saved_revision&.file&.attached?
      @session.saved_revision.file.open { |saved| final_checksum = DmsfOnlyofficeRecovery.checksum_for(saved) }
    end
    if checksum == final_checksum
      final&.record_request_receipts!(metadata)
      @session.update!(last_callback_at: Time.current)
      return Result.new(revision: @session.saved_revision, published: false, duplicate: true, state: 'saved')
    end

    reason = 'A late force-save differs from the published final revision; retained for manual recovery'
    recovery = DmsfOnlyofficeRecovery.store!(session: @session, kind: 'conflict', io: io,
                                             filename: filename, content_type: content_type,
                                             reason: reason, metadata: metadata)
    @session.update!(last_callback_at: Time.current, last_error: reason)
    Result.new(recovery: recovery, published: false, state: 'saved')
  end

  def capture_forms(recovery)
    io = download(@payload['formsdataurl'], max_bytes: FORMS_MAX_BYTES)
    values = JSON.parse(io.read)
    raise RedmineDmsf::OnlyOffice::Error, 'Invalid submitted form data' unless values.is_a?(Array) || values.is_a?(Hash)

    recovery.with_lock { recovery.update!(metadata: recovery.metadata.merge('forms_data' => values)) }
  rescue JSON::ParserError => e
    raise RedmineDmsf::OnlyOffice::Error, "Invalid submitted form JSON: #{e.message}"
  end

  def history_io
    return if @payload['changesurl'].blank?

    download(@payload['changesurl'])
  end

  def publish(recovery)
    file = @session.dmsf_file
    raise DmsfOnlyofficeRevisionWriter::Conflict, 'The original DMSF file has been deleted' unless file

    changes = history_io
    result = nil
    # Always lock the file before its session, matching registration/retention.
    file.with_lock do
      @session.with_lock do
        if @session.state == 'submitted' || @session.recoveries.exists?(kind: 'form')
          recovery = recovery.as_kind!('form')
          @session.update!(state: 'submitted', closed_at: @session.closed_at || Time.current,
                           last_callback_at: Time.current)
          result = Result.new(recovery: recovery, published: false, state: 'submitted')
        else
          existing = DmsfFileRevision.find_by(onlyoffice_key: @session.document_key)
          if existing || (@session.state == 'saved' && @session.saved_revision_id.present?)
            result = finish_duplicate(recovery, existing, changes)
          else
            source = @session.source_revision
            revision = DmsfOnlyofficeRevisionWriter.call(
              file: @session.dmsf_file, source: source, user: @user, io: recovery.payload.blob,
              filename: recovery.filename, content_type: recovery.content_type,
              key: @session.document_key, expected_revision_id: @session.source_revision_id,
              permission: DmsfOnlyofficeSession::MODE_PERMISSIONS.fetch(@mode)
            )
            DmsfOnlyofficeHistory.store!(revision: revision, source: source, metadata: @payload['history'], io: changes)
            finish_publication(recovery, revision)
            result = Result.new(revision: revision, recovery: recovery, published: true, duplicate: false,
                                state: 'saved')
          end
        end
      end
    end
    result
  rescue DmsfOnlyofficeRevisionWriter::Conflict, DmsfOnlyofficeRevisionWriter::PermissionDenied,
         ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
    recovery.update!(reason: e.message)
    @session.record_callback!(next_state: 'recovery', error: e.message, closed: true)
    Result.new(recovery: recovery, published: false, state: @session.state)
  end

  def finish_duplicate(recovery, revision, changes)
    revision_id = revision&.id || @session.saved_revision_id
    final = @session.recoveries.find_by(kind: 'final', state: 'imported', restored_revision_id: revision_id)
    checksum = final&.checksum
    if checksum.nil? && revision&.file&.attached?
      revision.file.open { |io| checksum = DmsfOnlyofficeRecovery.checksum_for(io) }
    end
    unless checksum == recovery.checksum
      reason = 'Another final callback published different bytes; this copy was retained for manual recovery'
      recovery = recovery.as_conflict!(reason)
      @session.update!(state: 'saved', saved_revision_id: revision_id, last_error: reason,
                       closed_at: @session.closed_at || Time.current, last_callback_at: Time.current)
      return Result.new(revision: revision, recovery: recovery, published: false, state: 'saved')
    end

    # The file lock prevents retention from removing this revision while a
    # missing legacy history record is filled in. Never recreate pruned history.
    if revision && !DmsfOnlyofficeHistory.exists?(dmsf_file_revision_id: revision.id)
      DmsfOnlyofficeHistory.store!(revision: revision, source: @session.source_revision,
                                   metadata: @payload['history'], io: changes)
    end
    finish_publication(recovery, revision, revision_id: revision_id)
    Result.new(revision: revision, recovery: recovery, published: false, duplicate: true, state: 'saved')
  end

  def finish_publication(recovery, revision, revision_id: revision&.id)
    recovery.update!(state: 'imported', restored_revision_id: revision_id)
    blob = recovery.payload.blob
    recovery.payload.detach
    DmsfOnlyofficeBlob.purge_if_unattached_after_commit(blob)
    DmsfOnlyofficeRecovery.remove_completed_snapshots!(@session, final: recovery)
    warning = @session.recoveries.pending.where.not(reason: [nil, '']).order(id: :desc).pick(:reason)
    @session.update!(state: 'saved', saved_revision_id: revision_id, last_error: warning,
                     closed_at: @session.closed_at || Time.current, last_callback_at: Time.current)
  end
end
