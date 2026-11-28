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

require File.expand_path('../test_helper', __dir__)
require 'stringio'

# Exercises retention against real revision chains and stored file contents.
class DmsfRevisionRetentionTest < RedmineDmsf::Test::UnitTest
  def setup
    super
    @original_settings = Setting.plugin_redmine_dmsf.dup
    Setting.plugin_redmine_dmsf = @original_settings.merge(
      'dmsf_minor_revision_retention_enabled' => '0',
      'dmsf_minor_revision_retention_limit' => '100',
      'dmsf_really_delete_files' => '1'
    )
    User.current = @admin
    @source = DmsfFileRevision.find(1)
    @revision_time = Time.current
  end

  def teardown
    Setting.plugin_redmine_dmsf = @original_settings
    User.current = nil
    super
  end

  def test_disabled_retention_does_not_delete_revisions
    revisions = Array.new(3) { |index| create_revision(minor: index + 1) }

    result = DmsfRevisionRetention.prune(@file1, limit: 1)

    assert_equal :disabled, result.skipped_reason
    assert_empty result.deleted_ids
    assert_equal revisions.size, DmsfFileRevision.where(id: revisions.map(&:id)).count
  end

  def test_keeps_latest_one_hundred_minor_revisions_across_major_releases
    first_minors = Array.new(55) { |index| create_revision(minor: index + 1) }
    release = create_revision(major: 2, minor: 0)
    later_minors = Array.new(50) { |index| create_revision(major: 2, minor: index + 1) }
    all_minors = first_minors + later_minors
    enable_retention

    result = DmsfRevisionRetention.prune(@file1)

    assert_equal all_minors.first(5).map(&:id).sort, result.deleted_ids.sort
    assert_equal all_minors.last(100).map(&:id).sort,
                 DmsfFileRevision.where(id: all_minors.map(&:id)).pluck(:id).sort
    assert DmsfFileRevision.exists?(@source.id)
    assert DmsfFileRevision.exists?(release.id)
    assert DmsfFileRevision.exists?(later_minors.last.id)
  end

  def test_numeric_alphabetic_and_empty_component_major_releases_are_preserved
    releases = [
      create_revision(major: 2, minor: 0, patch: 0),
      create_revision(major: 3, minor: nil),
      create_revision(major: -'A'.ord, minor: -' '.ord),
      create_revision(major: -'B'.ord, minor: 0, patch: -' '.ord)
    ]
    minor = create_revision(major: -'B'.ord, minor: 1)
    alphabetic_minor = create_revision(major: -'B'.ord, minor: -'A'.ord)
    patch = create_revision(major: -'B'.ord, minor: 0, patch: 1)
    current = create_revision(major: -'B'.ord, minor: 0, patch: 2)
    enable_retention(1)

    result = DmsfRevisionRetention.prune(@file1)

    assert_equal [minor.id, alphabetic_minor.id, patch.id].sort, result.deleted_ids.sort
    assert_equal releases.size, DmsfFileRevision.where(id: releases.map(&:id)).count
    assert DmsfFileRevision.exists?(current.id)
  end

  def test_same_timestamp_uses_id_to_keep_the_most_recent_revision
    older = create_revision(minor: 1)
    newer = create_revision(minor: 2, created_at: older.created_at)
    enable_retention(1)

    result = DmsfRevisionRetention.prune(@file1)

    assert_equal [older.id], result.deleted_ids
    assert DmsfFileRevision.exists?(newer.id)
  end

  def test_dry_run_reports_candidates_without_changing_sources_or_file_contents
    older = create_revision(minor: 1, content: 'Older document')
    newer = create_revision(minor: 2, source: older)
    enable_retention(1)

    result = DmsfRevisionRetention.prune(@file1, dry_run: true)

    assert_equal [older.id], result.candidate_ids
    assert_empty result.deleted_ids
    assert DmsfFileRevision.exists?(older.id)
    assert_equal older.id, newer.reload.source_dmsf_file_revision_id
    assert_equal 'Older document', newer.file.download
  end

  def test_explicit_invalid_limits_never_delete_any_revision
    older = create_revision(minor: 1)
    current = create_revision(minor: 2)
    enable_retention

    [0, -1, 'invalid', '', 1.5].each do |limit|
      assert_raises ArgumentError do
        DmsfRevisionRetention.prune(@file1, limit: limit)
      end
    end

    assert DmsfFileRevision.exists?(older.id)
    assert DmsfFileRevision.exists?(current.id)
  end

  def test_invalid_configured_limits_use_the_safe_default
    %w[0 -1 invalid].each do |limit|
      enable_retention(limit)
      assert_equal 100, RedmineDmsf.minor_revision_retention_limit
    end
    enable_retention(100_001)
    assert_equal 100_000, RedmineDmsf.minor_revision_retention_limit
  end

  def test_approved_and_in_progress_workflows_are_protected_above_the_limit
    protected = [
      DmsfWorkflow::STATE_APPROVED,
      DmsfWorkflow::STATE_WAITING_FOR_APPROVAL,
      DmsfWorkflow::STATE_ASSIGNED
    ].map.with_index { |workflow, index| create_revision(minor: index + 1, workflow: workflow) }
    rejected = create_revision(minor: 4, workflow: DmsfWorkflow::STATE_REJECTED)
    obsolete = create_revision(minor: 5, workflow: DmsfWorkflow::STATE_OBSOLETE)
    current = create_revision(minor: 6)
    enable_retention(1)

    result = DmsfRevisionRetention.prune(@file1)

    assert_equal [rejected.id, obsolete.id].sort, result.deleted_ids.sort
    protected.each do |revision|
      assert_equal [:workflow], result.protected_ids[revision.id]
      assert DmsfFileRevision.exists?(revision.id)
    end
    assert DmsfFileRevision.exists?(current.id)
  end

  def test_active_shared_editing_session_bases_are_protected
    active_base = create_revision(minor: 1)
    snapshot_base = create_revision(minor: 2)
    expired_base = create_revision(minor: 3)
    completed_base = create_revision(minor: 4)
    retired_base = create_revision(minor: 5)
    current = create_revision(minor: 6)
    create_session(active_base, state: 'active')
    create_session(snapshot_base, state: 'snapshot')
    create_session(expired_base, state: 'active', expires_at: 1.minute.ago)
    create_session(completed_base, state: 'saved')
    create_session(retired_base, state: 'active').update!(closed_at: 1.minute.ago)
    enable_retention(1)

    result = DmsfRevisionRetention.prune(@file1)

    assert_equal [expired_base.id, completed_base.id, retired_base.id].sort, result.deleted_ids.sort
    assert_equal [:editing_session], result.protected_ids[active_base.id]
    assert_equal [:editing_session], result.protected_ids[snapshot_base.id]
    assert DmsfFileRevision.exists?(current.id)
    # Session records remain available for auditing even if an expired base is pruned.
    assert DmsfOnlyofficeSession.exists?(source_revision_id: expired_base.id)
  end

  def test_locked_files_are_skipped_even_for_the_lock_owner
    older = create_revision(minor: 1)
    create_revision(minor: 2)
    @file1.lock!
    enable_retention(1)

    result = DmsfRevisionRetention.prune(@file1)

    assert_equal :locked, result.skipped_reason
    assert DmsfFileRevision.exists?(older.id)
  end

  def test_review_comment_and_fill_sessions_also_protect_their_bases
    protected = %w[review comment fill].map.with_index do |mode, index|
      revision = create_revision(minor: index + 1)
      create_session(revision, mode: mode, state: 'active')
      revision
    end
    create_revision(minor: 4)
    enable_retention(1)

    result = DmsfRevisionRetention.prune(@file1)

    assert_empty result.deleted_ids
    protected.each do |revision|
      assert_equal [:editing_session], result.protected_ids[revision.id]
      assert DmsfFileRevision.exists?(revision.id)
    end
  end

  def test_open_sessions_keep_their_base_after_callback_errors_or_pending_form_submission
    protected = %w[error recovery submitted].map.with_index do |state, index|
      revision = create_revision(minor: index + 1)
      create_session(revision, state: state, mode: state == 'submitted' ? 'fill' : 'edit')
      revision
    end
    closed_base = create_revision(minor: 4)
    terminal_base = create_revision(minor: 5)
    current = create_revision(minor: 6)
    create_session(closed_base, state: 'closed')
    create_session(terminal_base, state: 'error').update!(closed_at: 1.minute.ago)
    enable_retention(1)

    result = DmsfRevisionRetention.prune(@file1)

    assert_equal [closed_base.id, terminal_base.id].sort, result.deleted_ids.sort
    protected.each do |revision|
      assert_equal [:editing_session], result.protected_ids[revision.id]
      assert DmsfFileRevision.exists?(revision.id)
    end
    assert DmsfFileRevision.exists?(current.id)
  end

  def test_pending_document_operations_protect_their_source_revision
    pending_base = create_revision(minor: 1)
    completed_base = create_revision(minor: 2)
    current = create_revision(minor: 3)
    [pending_base, completed_base].each_with_index do |revision, index|
      DmsfOnlyofficeOperation.create!(
        request_key: "retention-operation-#{revision.id}",
        kind: 'pdf',
        dmsf_file: @file1,
        source_revision: revision,
        user: @admin,
        filename: 'export.pdf',
        state: index.zero? ? 'pending' : 'completed',
        parameters: {}
      )
    end
    enable_retention(1)

    result = DmsfRevisionRetention.prune(@file1)

    assert_equal [completed_base.id], result.deleted_ids
    assert_equal [:document_operation], result.protected_ids[pending_base.id]
    assert DmsfFileRevision.exists?(pending_base.id)
    assert DmsfFileRevision.exists?(current.id)
    assert DmsfOnlyofficeOperation.exists?(source_revision_id: completed_base.id)
  end

  def test_deleted_files_are_not_pruned
    older = create_revision(minor: 1)
    create_revision(minor: 2)
    @file1.update!(deleted: DmsfFile::STATUS_DELETED)
    enable_retention(1)

    result = DmsfRevisionRetention.prune(@file1)

    assert_equal :deleted, result.skipped_reason
    assert DmsfFileRevision.exists?(older.id)
  end

  def test_expired_pending_operations_do_not_protect_sources_indefinitely
    expired_base = create_revision(minor: 1)
    active_base = create_revision(minor: 2)
    current = create_revision(minor: 3)
    [expired_base, active_base].each_with_index do |revision, index|
      DmsfOnlyofficeOperation.create!(
        request_key: "retention-operation-expiry-#{revision.id}",
        kind: 'pdf',
        dmsf_file: @file1,
        source_revision: revision,
        user: @admin,
        filename: 'export.pdf',
        state: 'pending',
        parameters: {},
        created_at: index.zero? ? 25.hours.ago : Time.current
      )
    end
    enable_retention(1)

    result = DmsfRevisionRetention.prune(@file1)

    assert_equal [expired_base.id], result.deleted_ids
    assert_equal [:document_operation], result.protected_ids[active_base.id]
    assert DmsfFileRevision.exists?(current.id)
    assert DmsfOnlyofficeOperation.exists?(source_revision_id: expired_base.id, state: 'pending')
  end

  def test_pruning_preserves_bytes_for_all_branches_of_an_inherited_file
    original_content = @source.file.download
    older = create_revision(minor: 1, content: 'Shared edited document')
    release_one = create_revision(major: 2, minor: 0, source: older)
    release_two = create_revision(major: 3, minor: 0, source: older)
    current = create_revision(major: 3, minor: 1, source: older)
    enable_retention(1)

    result = DmsfRevisionRetention.prune(@file1)

    assert_equal [older.id], result.deleted_ids
    [release_one, release_two, current].each do |revision|
      revision.reload
      assert_not_equal older.id, revision.source_dmsf_file_revision_id
      assert_equal 'Shared edited document', revision.file.download
    end
    assert_equal original_content, @source.reload.file.download
  end

  def test_pruning_does_not_remove_a_blob_attached_to_an_independent_revision
    older = create_revision(minor: 1, content: 'Shared blob')
    current = create_revision(minor: 2)
    current.shared_file.attach(older.shared_file.blob)
    enable_retention(1)

    DmsfRevisionRetention.prune(@file1)

    assert_equal 'Shared blob', current.reload.file.download
    assert ActiveStorage::Blob.exists?(current.file.blob.id)
  end

  def test_pruning_multiple_inherited_revisions_reloads_the_rewired_chain
    original_content = @source.file.download
    older = create_revision(minor: 1)
    intermediate = create_revision(minor: 2, source: older)
    current = create_revision(minor: 3, source: intermediate)
    enable_retention(1)

    result = DmsfRevisionRetention.prune(@file1)

    assert_equal [older.id, intermediate.id].sort, result.deleted_ids.sort
    assert_equal @source.id, current.reload.source_dmsf_file_revision_id
    assert_equal original_content, current.file.download
  end

  def test_rollback_preserves_original_revision_and_file_bytes
    older = create_revision(minor: 1, content: 'Must survive rollback')
    create_revision(minor: 2, content: 'Current document')
    enable_retention(1)

    DmsfFileRevision.transaction(requires_new: true) do
      DmsfRevisionRetention.prune(@file1)
      assert_not DmsfFileRevision.exists?(older.id)
      raise ActiveRecord::Rollback
    end

    assert_equal 'Must survive rollback', older.reload.file.download
  end

  def test_retention_failure_does_not_turn_a_committed_revision_into_an_error
    revision = create_revision(minor: 1)
    enable_retention
    DmsfRevisionRetention.expects(:prune).with(revision.dmsf_file).raises(StandardError, 'cleanup unavailable')

    assert_nothing_raised { revision.prune_old_minor_revisions }
    assert DmsfFileRevision.exists?(revision.id)
  end

  private

  def enable_retention(limit = 100)
    Setting.plugin_redmine_dmsf = Setting.plugin_redmine_dmsf.merge(
      'dmsf_minor_revision_retention_enabled' => '1',
      'dmsf_minor_revision_retention_limit' => limit.to_s
    )
  end

  def create_revision(major: 1, minor: 1, patch: nil, source: @source, content: nil, workflow: nil, created_at: nil)
    revision = source.clone
    revision.reset_workflow
    @revision_time += 1.second
    revision.assign_attributes(
      major_version: major,
      minor_version: minor,
      patch_version: patch,
      workflow: workflow,
      created_at: created_at || @revision_time
    )
    if content
      revision.size = content.bytesize
      revision.shared_file.attach(io: StringIO.new(content), filename: revision.name, content_type: 'text/plain')
    end
    revision.save!
    revision
  end

  def create_session(source, state:, expires_at: 1.hour.from_now, mode: 'edit')
    DmsfOnlyofficeSession.create!(
      document_key: "retention-#{source.id}-#{state}",
      dmsf_file_id: @file1.id,
      source_revision_id: source.id,
      user_id: @admin.id,
      mode: mode,
      state: state,
      expires_at: expires_at
    )
  end
end
