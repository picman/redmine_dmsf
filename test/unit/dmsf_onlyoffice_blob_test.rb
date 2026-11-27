# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)
require 'active_job/test_helper'
require 'stringio'
require 'digest'

class DmsfOnlyofficeBlobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # Exercise real outer commits/rollbacks: transactional fixtures would delay the
  # upload callback until test teardown and conceal the storage-lifetime contract.
  self.use_transactional_tests = false

  def setup
    @uploaded = []
    @recovery = nil
    @editor_session = nil
  end

  def teardown
    @recovery&.payload&.detach
    @recovery&.destroy!
    @editor_session&.destroy!
    @uploaded.each do |upload|
      blob = ActiveStorage::Blob.find_by(key: upload[:key])
      blob&.purge
      upload[:service].delete(upload[:key])
    end
  end

  def test_outer_rollback_removes_the_uploaded_storage_key
    upload = nil
    ActiveRecord::Base.transaction do
      upload = upload_document('rolled back document')
      assert upload[:service].exist?(upload[:key])
      raise ActiveRecord::Rollback
    end

    assert_not ActiveStorage::Blob.exists?(key: upload[:key])
    assert_not upload[:service].exist?(upload[:key])
  end

  def test_committing_an_inner_transaction_does_not_survive_an_outer_rollback
    upload = nil
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.transaction(requires_new: true) do
        upload = upload_document('nested document')
      end
      assert upload[:service].exist?(upload[:key])
      raise ActiveRecord::Rollback
    end

    assert_not ActiveStorage::Blob.exists?(key: upload[:key])
    assert_not upload[:service].exist?(upload[:key])
  end

  def test_a_committed_attachment_keeps_its_original_bytes
    @editor_session = DmsfOnlyofficeSession.create!(
      document_key: "blob-test-#{SecureRandom.uuid}", dmsf_file_id: 0,
      mode: 'edit', state: 'active', expires_at: 1.hour.from_now
    )
    @recovery = DmsfOnlyofficeRecovery.create!(
      dmsf_onlyoffice_session: @editor_session, kind: 'error',
      checksum: Digest::SHA256.hexdigest('committed document'), filename: 'test.docx',
      content_type: 'application/octet-stream', state: 'pending'
    )
    upload = nil
    ActiveRecord::Base.transaction do
      upload = upload_document('committed document')
      @recovery.payload.attach(upload[:blob])
    end

    assert_equal 'committed document', @recovery.reload.payload.download
    assert ActiveStorage::Blob.exists?(key: upload[:key])
    assert upload[:service].exist?(upload[:key])

    ActiveRecord::Base.transaction { raise ActiveRecord::Rollback }
    assert_equal 'committed document', @recovery.reload.payload.download

    perform_enqueued_jobs(only: ActiveStorage::PurgeJob) do
      DmsfOnlyofficeBlob.purge_if_unattached_after_commit(upload[:blob])
    end
    assert_equal 'committed document', @recovery.reload.payload.download
  end

  def test_redundant_upload_cleanup_waits_for_the_outer_commit
    upload = upload_document('redundant document')

    perform_enqueued_jobs(only: ActiveStorage::PurgeJob) do
      ActiveRecord::Base.transaction do
        DmsfOnlyofficeBlob.purge_if_unattached_after_commit(upload[:blob])
        assert upload[:service].exist?(upload[:key])
        assert ActiveStorage::Blob.exists?(key: upload[:key])
      end
    end

    assert_not ActiveStorage::Blob.exists?(key: upload[:key])
    assert_not upload[:service].exist?(upload[:key])
  end

  def test_redundant_upload_cleanup_does_nothing_on_rollback
    upload = upload_document('still recoverable')

    perform_enqueued_jobs(only: ActiveStorage::PurgeJob) do
      ActiveRecord::Base.transaction do
        DmsfOnlyofficeBlob.purge_if_unattached_after_commit(upload[:blob])
        raise ActiveRecord::Rollback
      end
    end

    assert ActiveStorage::Blob.exists?(key: upload[:key])
    assert_equal 'still recoverable', upload[:blob].download
  end

  private

  def upload_document(bytes)
    blob = DmsfOnlyofficeBlob.upload!(io: StringIO.new(bytes), filename: 'test.docx',
                                     content_type: 'application/octet-stream', identify: false)
    upload = { blob: blob, key: blob.key, service: blob.service }
    @uploaded << upload
    upload
  end
end
