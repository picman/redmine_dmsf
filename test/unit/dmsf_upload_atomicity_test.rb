# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)
require 'tempfile'

# Ordinary upload failures must preserve both history and retryable attachments.
class DmsfUploadAtomicityTest < RedmineDmsf::Test::UnitTest
  def setup
    super
    User.current = @admin
    DmsfMailer.stubs(:deliver_files_updated).returns([])
    Redmine::Hook.stubs(:call_hook).returns([])
    @revision = @file1.last_revision
  end

  def teardown
    User.current = nil
    super
  end

  def test_missing_upload_bytes_leave_no_revision_or_orphan_document
    attachment = stub(diskfile: '/nonexistent/dmsf-review-upload')
    Attachment.stubs(:find_by_token).returns(attachment)
    [@revision.name, 'new-missing-upload.txt'].each do |name|
      assert_no_difference ['DmsfFile.count', 'DmsfFileRevision.count', 'ActiveStorage::Blob.count'] do
        files, failures = upload(name)
        assert_empty files
        assert_equal 1, failures.size
      end
    end
    assert_equal @revision.id, DmsfFile.find(@file1.id).last_revision.id
  end

  def test_storage_failure_rolls_back_the_revision_without_consuming_the_attachment
    io = Tempfile.new('dmsf-upload-test')
    io.write('replacement')
    io.flush
    attachment = mock
    attachment.stubs(:diskfile).returns(io.path)
    attachment.expects(:delete_from_disk).never
    attachment.expects(:destroy).never
    Attachment.stubs(:find_by_token).returns(attachment)
    DmsfOnlyofficeBlob.stubs(:upload!).raises(IOError, 'storage unavailable')

    assert_no_difference ['DmsfFileRevision.count', 'ActiveStorage::Blob.count'] do
      files, failures = upload(@revision.name)
      assert_empty files
      assert_equal 1, failures.size
    end
    assert_equal @revision.id, DmsfFile.find(@file1.id).last_revision.id
  ensure
    io&.close!
  end

  def test_success_publishes_the_uploaded_bytes_and_consumes_the_attachment
    io = Tempfile.new('dmsf-upload-test')
    io.write('replacement')
    io.flush
    attachment = mock
    attachment.stubs(:diskfile).returns(io.path)
    attachment.expects(:delete_from_disk).once
    attachment.expects(:destroy).once
    Attachment.stubs(:find_by_token).returns(attachment)

    assert_difference 'DmsfFileRevision.count', 1 do
      files, failures = upload(@revision.name)
      assert_empty failures
      assert_equal 'replacement', files.first.last_revision.file.download
    end
  ensure
    io&.close!
  end

  def test_duplicate_version_is_rejected_before_consuming_upload_bytes
    Attachment.expects(:find_by_token).never
    assert_no_difference 'DmsfFileRevision.count' do
      files, failures = upload(@revision.name, minor: @revision.minor_version.to_s)
      assert_empty files
      assert_equal 1, failures.size
    end
  end

  private

  def upload(name, minor: '1')
    DmsfUploadHelper.commit_files_internal(
      { '0' => { name: name, title: 'Upload test', token: 'test-token',
                 version_major: '1', version_minor: minor, size: 11, mime_type: 'text/plain' } },
      @project1, @file1.dmsf_folder
    )
  end
end
