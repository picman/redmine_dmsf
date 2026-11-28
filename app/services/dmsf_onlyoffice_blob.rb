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

# Uploads are synchronous, but their storage keys must follow the outer database
# transaction: a rolled-back Blob row must not leave unreachable document bytes.
class DmsfOnlyofficeBlob
  # Upload class
  class Upload
    def initialize(blob)
      # ActiveRecord can clear the new record's id on rollback, so retain the
      # immutable storage identity instead of inspecting that record afterwards.
      @key = blob.key
      @service = blob.service
    end

    def trigger_transactional_callbacks?
      false
    end

    def before_committed!(*); end
    def committed!(*, **); end

    def rolledback!(*, **)
      # Never remove a key that still has a database owner. This also protects a
      # reference created by a caller that handles a nested rollback explicitly.
      return if ActiveStorage::Blob.exists?(key: @key)

      @service.delete(@key)
    rescue StandardError => e
      Rails.logger.error "Could not clean up rolled-back ONLYOFFICE upload #{@key}: #{e.class}: #{e.message}"
    end
  end

  # Purge class
  class Purge
    def initialize(blob)
      @key = blob.key
    end

    def trigger_transactional_callbacks?
      false
    end

    def before_committed!(*); end
    def rolledback!(*, **); end

    def committed!(*, **)
      blob = ActiveStorage::Blob.find_by(key: @key)
      return unless blob && !blob.attachments.exists?

      # ActiveStorage rechecks reference constraints when the purge job executes.
      blob.purge_later
    rescue StandardError => e
      Rails.logger.error "Could not purge redundant ONLYOFFICE upload #{@key}: #{e.class}: #{e.message}"
    end
  end

  def self.upload!(**parameters)
    ActiveStorage::Blob.transaction(requires_new: true) do
      blob = ActiveStorage::Blob.create_after_unfurling!(**parameters)
      ActiveStorage::Blob.connection.add_transaction_record(Upload.new(blob))
      blob.upload_without_unfurling(parameters.fetch(:io))
      blob
    end
  end

  def self.purge_if_unattached_after_commit(blob)
    ActiveStorage::Blob.transaction do
      ActiveStorage::Blob.connection.add_transaction_record(Purge.new(blob))
    end
  end
end
