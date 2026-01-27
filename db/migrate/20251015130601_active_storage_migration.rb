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

# Migrate documents to/from Active Storage
class ActiveStorageMigration < ActiveRecord::Migration[7.0]
  # File system -> Active Storage
  def up
    $stdout.puts 'It could be a very long process. Be patient...'
    # We need to keep updated_at column unchanged and due to the asynchronous file analysis there is probably no better
    # way how to achieve that.
    add_column :dmsf_file_revisions, :temp_updated_at, :datetime,
               default: nil, null: true, if_not_exists: true
    DmsfFileRevision.update_all 'temp_updated_at = updated_at'
    # Switch of Xapian
    xapian_available = RedmineDmsf.xapian_available
    RedmineDmsf.xapian_available = false
    # Index files
    path = DmsfFile.storage_path.join('**/*')
    $stdout.puts path
    Dir.glob(path.join('**/*')).each do |path|
      # Print out the currently processed directory
      unless File.file?(path)
        $stdout.puts path
        next
      end
      # Process a file
      disk_filename = File.basename(path)
      $stdout.print path
      found = false
      DmsfFileRevision.where(disk_filename: disk_filename)
                      .order(source_dmsf_file_revision_id: :asc)
                      .each
                      .with_index do |r, i|
        found = true
        if i.zero?
          r.shared_file.attach io: File.open(path), filename: r.name
          # Remove the original file
          FileUtils.rm(path) if RedmineDmsf.physical_file_delete?
          key = r.shared_file.blob.key
          $stdout.puts " => #{File.join(key[0..1], key[2..3], key)} (#{r.shared_file.blob.filename})"
        else
          # The other revisions should have set the source revision
          warn("r#{r.id}.source_dmsf_file_revision_id is null") unless r.source_dmsf_file_revision_id
        end
      end
      found ? $stdout.print("\n") : $stdout.print(" revision not found, skipped\n")
    end
    # Remove columns duplicated in ActiveStorage
    remove_column :dmsf_file_revisions, :digest
    remove_column :dmsf_file_revisions, :mime_type
    remove_column :dmsf_file_revisions, :disk_filename
    remove_column :dmsf_files, :name
    # We need to keep the size despite the fact that it's duplicated in active_storage_blobs to speed up the main
    # document view
    # Restore updated_at column
    DmsfFileRevision.update_all 'updated_at = temp_updated_at'
    remove_column :dmsf_file_revisions, :temp_updated_at
    # Restore Xapian availability
    RedmineDmsf.xapian_available = xapian_available
    $stdout.puts "Don't forget to rebuild Xapian database using redmine:dmsf_analysis rake task."
    $stdout.puts 'Prior of this task remove the present Xapian database.'
    $stdout.puts 'Done'
  end

  # Active Storage -> File system
  def down
    $stdout.puts 'It could be a very long process. Be patient...'
    # Restore removed columns
    add_column :dmsf_file_revisions, :digest, :string, limit: 64, default: '', null: false
    add_column :dmsf_file_revisions, :mime_type, :string
    add_column :dmsf_file_revisions, :disk_filename, :string, default: '', null: false
    add_column :dmsf_files, :name, :string, default: '', null: false
    # Migrate attachments
    ActiveStorage::Attachment.find_each do |a|
      r = a.record
      new_path = disk_file(r, a)
      unless File.exist?(new_path)
        a.blob.open do |f|
          # Move the attachment
          FileUtils.mv f.path, new_path
          r.record_timestamps = false # Do not modify updated_at column
          DmsfFileRevision.no_touching do
            # Mime type
            r.mime_type = a.blob.content_type
            # Disk filename
            r.disk_filename = File.basename(new_path)
            # Digest
            # We leave the digest calculation to dmsf_create_digests.rake task
            r.save
          end
          r.dmsf_file.record_timestamps = false # Do not modify updated_at column
          DmsfFile.no_touching do
            # Filename
            r.dmsf_file.name = r.dmsf_file.last_revision.name
            r.dmsf_file.save
          end
        end
        key = a.blob.key
        $stdout.puts "#{File.join(key[0..1], key[2..3], key)} (#{a.blob.filename}) => #{new_path}"
      end
      # Remove the original file
      r.record_timestamps = false # Do not modify updated_at column
      DmsfFileRevision.no_touching do
        a.purge
      end
    end
    $stdout.puts "Don't forget to rebuild Xapian database using extra/xapian_indexer.rb."
    $stdout.puts 'Prior of this task remove the present Xapian database.'
    $stdout.puts 'Done'
  end

  private

  def storage_base_path(rev)
    time = rev.created_at || DateTime.current
    storage_path.join(time.strftime('%Y')).join time.strftime('%m')
  end

  def new_storage_filename(rev, name)
    filename = DmsfHelper.sanitize_filename(name)
    timestamp = DateTime.current.strftime('%y%m%d%H%M%S')
    timestamp.succ! while File.exist? storage_base_path(rev).join("#{timestamp}_#{rev.dmsf_file.id}_#{filename}")
    "#{timestamp}_#{rev.dmsf_file.id}_#{filename}"
  end

  def disk_file(rev, attachment)
    path = storage_base_path(rev)
    begin
      FileUtils.mkdir_p path
    rescue StandardError => e
      Rails.logger.error e.message
    end
    filename = new_storage_filename(rev, attachment.blob&.filename&.to_s)
    path.join(filename).to_s
  end
end
