# frozen_string_literal: true

require 'digest'

# An acquired working copy can be retained without becoming a DMSF revision.
class DmsfOnlyofficeRecovery < ApplicationRecord
  belongs_to :dmsf_onlyoffice_session, inverse_of: :recoveries
  belongs_to :restored_revision, class_name: 'DmsfFileRevision', optional: true
  has_one_attached :payload, dependent: :purge_later
  serialize :metadata, coder: JSON, type: Hash

  validates :kind, presence: true, length: { maximum: 32 }
  validates :checksum, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :filename, :content_type, presence: true
  validates :state, inclusion: { in: %w[pending imported] }

  scope :pending, -> { where(state: 'pending') }

  def self.checksum_for(io)
    digest = Digest::SHA256.new
    io.rewind
    while (chunk = io.read(64.kilobytes))
      digest << chunk
    end
    io.rewind
    digest.hexdigest
  end

  def self.store!(session:, kind:, io:, filename:, content_type:, reason: nil, metadata: {})
    checksum = checksum_for(io)
    result = nil
    session.with_lock do
      result = find_or_initialize_by(dmsf_onlyoffice_session: session, kind: kind, checksum: checksum)
      previous = result.metadata || {}
      incoming = metadata.deep_stringify_keys
      request_ids = request_receipts(previous, incoming)
      result.assign_attributes(filename: File.basename(filename.to_s), content_type: content_type,
                               reason: reason || result.reason,
                               metadata: previous.merge(incoming).merge('request_ids' => request_ids))
      unless result.payload.attached?
        # Upload before acknowledging a callback. Attaching an IO alone defers the
        # upload to after_commit, which could leave a database row without bytes.
        restored_blob = result.restored_revision&.file&.blob if result.state == 'imported'
        blob = restored_blob || DmsfOnlyofficeBlob.upload!(io: io, filename: result.filename,
                                                         content_type: content_type, identify: false)
        result.size = blob.byte_size
        result.payload.attach(blob)
      end
      result.save!
      result.prune_older_snapshots! if kind == 'snapshot' && result.state == 'pending' && result.reason.blank?
    end
    result
  ensure
    io&.rewind
  end

  def mark_imported!(revision)
    update!(state: 'imported', restored_revision: revision)
  end

  def self.request_receipts(*entries)
    entries.flat_map { |entry| Array(entry['request_ids']) + Array(entry['userdata']) }
           .map(&:to_s).reject(&:blank?).uniq.last(20)
  end

  def record_request_receipts!(incoming)
    update!(metadata: metadata.merge('request_ids' => self.class.request_receipts(metadata, incoming)))
  end

  def as_conflict!(reason)
    as_kind!('conflict', reason: reason)
  end

  def as_kind!(kind, reason: nil)
    existing = self.class.find_by(dmsf_onlyoffice_session_id: dmsf_onlyoffice_session_id,
                                  kind: kind, checksum: checksum)
    if existing && existing.id != id
      existing.update!(reason: reason, metadata: existing.metadata.merge(metadata))
      destroy!
      existing
    else
      update!(kind: kind, state: 'pending', reason: reason, restored_revision_id: nil)
      self
    end
  end

  def prune_older_snapshots!
    limit = RedmineDmsf.onlyoffice_snapshot_limit
    # Called only after the newest upload has completed and its row is saved,
    # in the same session transaction. Attachment purging runs after commit.
    self.class.where(dmsf_onlyoffice_session_id: dmsf_onlyoffice_session_id, kind: 'snapshot', state: 'pending')
        .where(reason: [nil, '']).where.not(id: id)
        .order(updated_at: :desc, id: :desc).offset(limit - 1).each(&:destroy!)
  end

  def self.remove_completed_snapshots!(session, final:)
    snapshots = where(dmsf_onlyoffice_session: session, kind: 'snapshot', state: 'pending')
                .where(reason: [nil, '']).to_a
    # A browser can poll after the final callback has already removed its draft.
    # Keep the exact receipts without keeping those redundant document bytes.
    receipts = request_receipts(*snapshots.map(&:metadata), final.metadata)
    final.update!(metadata: final.metadata.merge('request_ids' => receipts))
    snapshots.each(&:destroy!)
  end
end
