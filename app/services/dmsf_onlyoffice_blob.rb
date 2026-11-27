# frozen_string_literal: true

# Uploads are synchronous, but their storage keys must follow the outer database
# transaction: a rolled-back Blob row must not leave unreachable document bytes.
class DmsfOnlyofficeBlob
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
    ActiveStorage::Blob.transaction do
      blob = ActiveStorage::Blob.create_and_upload!(**parameters)
      ActiveStorage::Blob.connection.add_transaction_record(Upload.new(blob))
      blob
    end
  end

  def self.purge_if_unattached_after_commit(blob)
    ActiveStorage::Blob.transaction do
      ActiveStorage::Blob.connection.add_transaction_record(Purge.new(blob))
    end
  end
end
