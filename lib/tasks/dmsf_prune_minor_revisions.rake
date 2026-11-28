# frozen_string_literal: true

desc <<~END_DESC
  Preview or prune old minor/patch revisions using the configured DMSF retention policy.
  Retention must be enabled in the plugin settings. All major releases are preserved.
  Protected editing bases, pending operations, and approved/in-progress workflows may
  keep the minor count above the configured limit. Locked and deleted files are skipped.
  Physical file cleanup follows the existing DMSF file deletion setting.

  Available options:
    * dry_run - true (default) previews the candidates; false deletes eligible revisions
    * file_id - optionally limit the operation to one DMSF file

  Examples:
    rake redmine:dmsf_prune_minor_revisions RAILS_ENV=production
    rake redmine:dmsf_prune_minor_revisions dry_run=false file_id=123 RAILS_ENV=production
END_DESC

namespace :redmine do
  task dmsf_prune_minor_revisions: :environment do
    unless RedmineDmsf.minor_revision_retention_enabled?
      puts 'Minor revision retention is disabled; no revisions were changed.'
      next
    end

    dry_run_value = ENV.fetch('dry_run', 'true').downcase
    abort 'dry_run must be true or false' unless %w[true false 1 0].include?(dry_run_value)
    dry_run = %w[true 1].include?(dry_run_value)
    files = DmsfFile.visible
    if ENV['file_id'].present?
      file_id = Integer(ENV['file_id'], 10)
      abort 'file_id must be a positive integer' unless file_id.positive?
      files = files.where(id: file_id)
    end

    candidates = 0
    deleted = 0
    failures = 0
    files.find_each do |file|
      result = DmsfRevisionRetention.prune(file, dry_run: dry_run)
      candidates += result.candidate_ids.size
      deleted += result.deleted_ids.size
      if result.skipped_reason
        puts "File #{file.id}: skipped (#{result.skipped_reason})"
      elsif result.candidate_ids.any? || result.protected_ids.any?
        action = dry_run ? 'would remove' : 'removed'
        puts "File #{file.id}: #{action} #{result.candidate_ids.size} minor/patch revisions: " \
             "#{result.candidate_ids.join(', ')}"
        result.protected_ids.each do |revision_id, reasons|
          puts "  Retained above limit: revision #{revision_id} (#{reasons.join(', ')})"
        end
      end
    rescue StandardError => e
      failures += 1
      warn "File #{file.id}: cleanup failed: #{e.class}: #{e.message}"
    end
    puts "#{dry_run ? 'Preview' : 'Cleanup'} complete: " \
         "#{candidates} candidates, #{deleted} deleted, #{failures} failures."
    abort 'Some files could not be processed; see the errors above.' if failures.positive?
  end
end
