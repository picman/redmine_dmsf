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

# ONLYOFFICE History model
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
