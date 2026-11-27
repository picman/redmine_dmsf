# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)
require 'stringio'

class OnlyofficePersistenceTest < RedmineDmsf::Test::UnitTest
  def setup
    super
    @source = @file1.last_revision
    @key = RedmineDmsf::OnlyOffice.document_key(@file1, @source)
    RedmineDmsf.stubs(:onlyoffice_session_ttl).returns(30.days.to_i)
    RedmineDmsf.stubs(:onlyoffice_snapshot_limit).returns(2)
    RedmineDmsf.stubs(:onlyoffice_version_constant).returns(DmsfFileRevision::MINOR_VERSION)
    DmsfMailer.stubs(:deliver_files_updated)
  end

  def teardown
    User.current = nil
    super
  end

  def test_collaborators_share_a_key_without_replacing_its_owner_or_shortening_expiry
    first = DmsfOnlyofficeSession.register!(file: @file1, revision: @source, user: @jsmith,
                                           mode: 'edit', document_key: @key, expires_at: 1.hour.from_now)
    first_expiry = first.reload.expires_at
    joined = DmsfOnlyofficeSession.register!(file: @file1, revision: @source, user: @admin,
                                            mode: 'comment', document_key: @key, expires_at: 1.minute.from_now)
    assert_equal first.id, joined.id
    assert_equal @jsmith.id, joined.user_id
    assert_equal 'edit', joined.mode
    assert_equal first_expiry, joined.expires_at
    assert_equal [@jsmith.id.to_s, @admin.id.to_s].sort, joined.participants.sort
    assert joined.participant?(@admin)
  end

  def test_presence_updates_do_not_grant_session_membership
    session = register_session
    session.record_callback!(next_state: 'active', connected_users: [@jsmith.id.to_s, 'unregistered-user'],
                             presence_only: true)
    assert_equal [@jsmith.id.to_s], session.participants
    assert_equal [@jsmith.id.to_s, 'unregistered-user'], session.connected_users
    assert session.last_presence_at
    session.record_callback!(next_state: 'closed', connected_users: [], presence_only: true)
    assert_empty session.connected_users
    assert_equal [@jsmith.id.to_s], session.participants
  end

  def test_presence_does_not_reopen_a_terminal_generation_or_clear_its_warning
    session = register_session
    session.record_callback!(next_state: 'recovery', error: 'A conflicting final was retained', closed: true)
    closed_at = session.reload.closed_at
    [1, 4].each do |status|
      session.record_callback!(next_state: status == 1 ? 'active' : 'closed', connected_users: [],
                               presence_only: true)
      assert_equal 'recovery', session.state
      assert_equal 'A conflicting final was retained', session.last_error
      assert_equal closed_at, session.closed_at
    end
    assert_not_equal session.document_key, editor_key(@jsmith, 'edit')
  end

  def test_collaborators_and_an_unchanged_reconnect_share_the_live_generation
    session = register_session
    assert_equal session.document_key, editor_key(@admin, 'review')
    assert_equal session.document_key, editor_key(@admin, 'comment')
    session.record_callback!(next_state: 'closed', connected_users: [], presence_only: true)
    assert_nil session.closed_at
    assert_equal session.document_key, editor_key(@admin, 'edit')
    joined = DmsfOnlyofficeSession.register!(file: @file1, revision: @source, user: @admin,
                                            mode: 'edit', document_key: editor_key(@admin, 'edit'))
    assert_equal session.id, joined.id
    assert_equal 'active', joined.state
  end

  def test_late_snapshots_preserve_failure_state_and_reason
    session = register_session
    %w[error recovery].each do |state|
      session.update!(state: state, last_error: 'Unresolved final save', closed_at: Time.current)
      closed_at = session.closed_at
      session.record_callback!(next_state: 'snapshot')
      assert_equal state, session.reload.state
      assert_equal 'Unresolved final save', session.last_error
      assert_equal closed_at, session.closed_at
    end
  end

  def test_a_form_uses_a_new_generation_only_after_the_terminal_callback
    key = editor_key(@jsmith, 'fill')
    session = DmsfOnlyofficeSession.register!(file: @file1, revision: @source, user: @jsmith,
                                             mode: 'fill', document_key: key)
    assert_not_equal key, editor_key(@admin, 'fill')
    session.record_callback!(next_state: 'submitted')
    assert_equal key, editor_key(@jsmith, 'fill')
    session.record_callback!(next_state: 'submitted', closed: true)
    new_key = editor_key(@jsmith, 'fill')
    assert_not_equal key, new_key
    reopened = DmsfOnlyofficeSession.register!(file: @file1, revision: @source, user: @jsmith,
                                              mode: 'fill', document_key: new_key)
    assert_not_equal session.id, reopened.id
    assert_equal @source.id, reopened.source_revision_id
    assert_equal new_key, editor_key(@jsmith, 'fill')
  end

  def test_identical_snapshots_are_deduplicated_but_final_capture_is_distinct
    session = register_session
    first = store_capture(session, 'snapshot', 'working bytes')
    duplicate = store_capture(session, 'snapshot', 'working bytes')
    final = store_capture(session, 'final', 'working bytes')
    assert_equal first.id, duplicate.id
    assert_not_equal first.id, final.id
    assert_equal Digest::SHA256.hexdigest('working bytes'), first.checksum
    assert_equal 'working bytes', first.payload.download
    assert_equal 'pending', first.state
  end

  def test_a_historical_restore_advances_the_current_version_and_keeps_original_metadata
    User.current = @jsmith
    original_bytes = @source.file.download
    newer = @source.clone
    newer.major_version = 8
    newer.minor_version = 5
    newer.patch_version = 2
    newer.save!
    @file1.last_revision = newer
    @file1.save!

    restored = DmsfOnlyofficeRevisionWriter.call(file: @file1, source: @source, user: @jsmith,
                                                expected_revision_id: newer.id, key: 'restore-monotonic')
    assert_equal 8, restored.major_version
    assert_equal 6, restored.minor_version
    assert_nil restored.patch_version
    assert_equal @source.title, restored.title
    assert_equal @source.id, restored.source_revision.id
    assert_equal original_bytes, restored.file.download
    assert_equal restored.id, @file1.reload.dmsf_file_revisions.visible.first.id
  end

  def test_snapshot_limit_prunes_only_after_success_and_preserves_other_recovery_kinds
    session = register_session
    oldest = store_capture(session, 'snapshot', 'first draft')
    second = store_capture(session, 'snapshot', 'second draft')
    form = store_capture(session, 'form', 'submitted form')
    error = store_capture(session, 'error', 'recoverable error')

    DmsfOnlyofficeBlob.stubs(:upload!).raises(IOError, 'Storage unavailable')
    assert_raises IOError do
      store_capture(session, 'snapshot', 'failed draft')
    end
    assert DmsfOnlyofficeRecovery.exists?(oldest.id)
    assert DmsfOnlyofficeRecovery.exists?(second.id)
    DmsfOnlyofficeBlob.unstub(:upload!)

    newest = store_capture(session, 'snapshot', 'third draft')
    assert_not DmsfOnlyofficeRecovery.exists?(oldest.id)
    assert DmsfOnlyofficeRecovery.exists?(second.id)
    assert_equal 'third draft', newest.payload.download
    assert DmsfOnlyofficeRecovery.exists?(form.id)
    assert DmsfOnlyofficeRecovery.exists?(error.id)
  end

  def test_a_changed_head_rejects_publication_and_restores_the_callers_user_context
    User.current = @admin
    assert_no_difference 'DmsfFileRevision.count' do
      assert_raises DmsfOnlyofficeRevisionWriter::Conflict do
        DmsfOnlyofficeRevisionWriter.call(file: @file1, source: @source, user: @jsmith,
                                          expected_revision_id: -1, key: 'stale-head')
      end
    end
    assert_equal @admin, User.current
  end

  def test_publishing_a_durable_capture_reuses_its_uploaded_blob
    session = register_session
    capture = store_capture(session, 'final', 'captured bytes')
    revision = nil
    assert_no_difference 'ActiveStorage::Blob.count' do
      revision = DmsfOnlyofficeRevisionWriter.call(file: @file1, source: @source, user: @jsmith,
                                                  io: capture.payload.blob, filename: capture.filename,
                                                  expected_revision_id: @source.id, key: @key)
    end
    assert_equal capture.payload.blob.id, revision.file.blob.id
    assert_equal 'captured bytes', revision.file.download
  end

  def test_two_already_acquired_finals_preserve_the_losing_bytes_as_a_conflict
    session = register_session
    # Both callbacks have completed their downloads before either can publish.
    first = store_capture(session, 'final', 'first final bytes')
    second = store_capture(session, 'final', 'different concurrent final bytes')
    first_result = second_result = nil
    assert_difference 'DmsfFileRevision.count', 1 do
      first_result = capture_service(session).send(:publish, first)
      second_result = capture_service(session).send(:publish, second)
    end

    assert first_result.published
    assert_not second_result.published
    assert_equal 'first final bytes', first_result.revision.file.download
    assert_not first.reload.payload.attached?
    assert_equal 'conflict', second.reload.kind
    assert_equal 'pending', second.state
    assert_equal 'different concurrent final bytes', second.payload.download
    assert_equal first_result.revision.id, session.reload.saved_revision_id
    assert_equal 'saved', session.state
    assert_match(/different bytes/, session.last_error)
  end

  def test_publication_requires_the_explicit_mode_permission
    @manager_role.remove_permission!(:file_manipulation)
    @manager_role.add_permission!(:review_dmsf_files)
    assert_raises DmsfOnlyofficeRevisionWriter::PermissionDenied do
      DmsfOnlyofficeRevisionWriter.call(file: @file1, source: @source, user: @jsmith,
                                        expected_revision_id: @source.id)
    end
    revision = DmsfOnlyofficeRevisionWriter.call(file: @file1, source: @source, user: @jsmith,
                                                expected_revision_id: @source.id,
                                                permission: :review_dmsf_files)
    assert_equal @jsmith.id, revision.user_id
  end

  private

  def register_session
    DmsfOnlyofficeSession.register!(file: @file1, revision: @source, user: @jsmith,
                                    mode: 'edit', document_key: @key)
  end

  def editor_key(user, mode)
    @file1.with_lock do
      DmsfOnlyofficeSession.key_for_editor(file: @file1, revision: @source, user: user, mode: mode)
    end
  end

  def capture_service(session)
    DmsfOnlyofficeCapture.new(session: session, payload: { 'status' => 2 }, user: @jsmith, mode: 'edit')
  end

  def store_capture(session, kind, bytes)
    DmsfOnlyofficeRecovery.store!(session: session, kind: kind, io: StringIO.new(bytes),
                                  filename: @source.name, content_type: @source.content_type)
  end
end
