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

# Keeps a bounded number of minor/patch revisions without discarding releases or
# the revisions that an editor, document operation, or approval still needs.
class DmsfRevisionRetention
  EMPTY_VERSION_COMPONENTS = [nil, 0, -' '.ord].freeze
  PROTECTED_WORKFLOWS = [
    DmsfWorkflow::STATE_ASSIGNED,
    DmsfWorkflow::STATE_WAITING_FOR_APPROVAL,
    DmsfWorkflow::STATE_APPROVED
  ].freeze

  Result = Struct.new(
    :file_id, :limit, :dry_run, :candidate_ids, :deleted_ids, :protected_ids, :skipped_reason,
    keyword_init: true
  )

  def self.prune(file, dry_run: false, limit: nil)
    new(file, dry_run: dry_run, limit: limit).prune
  end

  def self.major_revision?(revision)
    EMPTY_VERSION_COMPONENTS.include?(revision.minor_version) &&
      EMPTY_VERSION_COMPONENTS.include?(revision.patch_version)
  end

  def initialize(file, dry_run: false, limit: nil)
    @file = file
    @result = Result.new(
      file_id: file.id,
      limit: limit.nil? ? RedmineDmsf.minor_revision_retention_limit : limit,
      dry_run: dry_run,
      candidate_ids: [],
      deleted_ids: [],
      protected_ids: {}
    )
  end

  def prune
    unless RedmineDmsf.minor_revision_retention_enabled?
      @result.skipped_reason = :disabled
      return @result
    end

    validate_limit!
    # Session registration and ONLYOFFICE saves use this same lock. Query all
    # protections after taking it, so an open editing session cannot lose its base.
    DmsfFile.transaction do
      @file = DmsfFile.lock.find(@file.id)
      if @file.deleted? || @file.locked?
        @result.skipped_reason = @file.deleted? ? :deleted : :locked
        next
      end

      revisions = @file.dmsf_file_revisions.visible.reorder(created_at: :desc, id: :desc).lock.to_a
      current_id = revisions.first&.id
      minor_revisions = revisions.reject { |revision| self.class.major_revision?(revision) }
      overflow = minor_revisions.drop(@result.limit)
      next if overflow.empty?

      session_bases = active_session_bases
      operation_bases = pending_operation_bases(overflow.map(&:id))
      candidates = overflow.reject do |revision|
        reasons = []
        reasons << :current if revision.id == current_id
        reasons << :workflow if PROTECTED_WORKFLOWS.include?(revision.workflow)
        reasons << :editing_session if session_bases.include?(revision.id)
        reasons << :document_operation if operation_bases.include?(revision.id)
        @result.protected_ids[revision.id] = reasons if reasons.any?
        reasons.any?
      end
      @result.candidate_ids = candidates.map(&:id)
      next if @result.dry_run

      # Delete oldest first, using the ordinary lifecycle so shared blobs and
      # source links are transferred before the next candidate is processed.
      candidates.reverse_each do |revision|
        # Deleting an earlier candidate can rewire this candidate's source and
        # transfer a blob to it. Do not destroy a stale copy of that chain.
        revision.reload
        unless revision.delete(commit: true)
          raise ActiveRecord::RecordNotDestroyed.new(revision.errors.full_messages.to_sentence, revision)
        end

        @result.deleted_ids << revision.id
      end
    end
    @result
  end

  private

  def validate_limit!
    @result.limit = Integer(@result.limit.to_s, 10)
    raise ArgumentError, 'The minor revision retention limit must be a positive integer' unless @result.limit.positive?
  rescue ArgumentError, TypeError
    raise ArgumentError, 'The minor revision retention limit must be a positive integer'
  end

  def active_session_bases
    return [] unless defined?(DmsfOnlyofficeSession) && DmsfOnlyofficeSession.table_exists?

    DmsfOnlyofficeSession.where(dmsf_file_id: @file.id, mode: DmsfOnlyofficeSession::MODE_PERMISSIONS.keys,
                                state: %w[active snapshot error recovery submitted], closed_at: nil)
                         .where('expires_at > ?', Time.current)
                         .distinct.pluck(:source_revision_id)
  end

  def pending_operation_bases(revision_ids)
    return [] unless defined?(DmsfOnlyofficeOperation) && DmsfOnlyofficeOperation.table_exists?

    DmsfOnlyofficeOperation.where(source_revision_id: revision_ids, state: 'pending')
                           .where('created_at > ?', 24.hours.ago)
                           .distinct.pluck(:source_revision_id)
  end
end
