# frozen_string_literal: true

class DmsfOnlyofficeHistory < ApplicationRecord
  belongs_to :dmsf_file_revision
  belongs_to :source_revision, class_name: 'DmsfFileRevision', optional: true
  # `changes` is reserved by ActiveRecord::Dirty.
  has_one_attached :changes_archive
  serialize :metadata, coder: JSON, type: Hash

  def self.store!(revision:, source:, metadata:, io: nil)
    history = find_or_initialize_by(dmsf_file_revision: revision)
    history.source_revision = source
    history.metadata = metadata.is_a?(Hash) ? metadata.deep_stringify_keys.slice('changes', 'serverVersion') : {}
    if io && !history.changes_archive.attached?
      io.rewind
      blob = DmsfOnlyofficeBlob.upload!(io: io, filename: "revision-#{revision.id}-changes.zip",
                                       content_type: 'application/zip', identify: false)
      history.changes_archive.attach(blob)
    end
    history.save!
    history
  end
end
