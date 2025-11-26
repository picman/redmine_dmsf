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
    # Remove the Xapian database as it will be rebuilt from scratch during the migration
    if xapian_database_removed?
      $stdout.puts 'The Xapian database has been removed as it will be rebuilt from scratch during the migration'
    end
    Dir.glob(DmsfFile.storage_path.join('**/*')).each do |path|
      # Print out the currently processed directory
      unless File.file?(path)
        $stdout.puts path
        next
      end
      # Process a file
      disk_filename = File.basename(path)
      DmsfFileRevision.where(disk_filename: disk_filename)
                      .order(source_dmsf_file_revision_id: :asc)
                      .find_each
                      .with_index do |r, i|
        if i.zero?
          r.file.attach(
            io: File.open(path),
            filename: r.name,
            content_type: r.mime_type,
            identify: false
          )
          # Remove the original file
          FileUtils.rm path
          key = r.file.blob.key
          $stdout.puts "#{path} => #{File.join(key[0..1], key[2..3], key)} (#{r.file.blob.filename})"
        else
          # The other revisions should have set the source revision
          warn("r#{r.id}.source_dmsf_file_revision_id is null") unless r.source_dmsf_file_revision_id
        end
      end
    end
    $stdout.puts 'Done'
  end

  # Active Storage -> File system
  def down
    $stdout.puts 'It could be a very long process. Be patient...'
    ActiveStorage::Attachment.find_each do |a|
      r = a.record
      new_path = r.disk_file(search_if_not_exists: false)
      unless File.exist?(new_path)
        a.blob.open do |f|
          FileUtils.mv f.path, new_path
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
    # Remove the Xapian database as it is useless now and has to be rebuilt with xapian_indexer.rb
    if xapian_database_removed?
      $stdout.puts 'Xapian database have been removed as it is useless now and has to be rebuilt with xapian_indexer.rb'
    end
    $stdout.puts 'Done'
  end

  private

  # Delete Xapian database
  def xapian_database_removed?
    if RedmineDmsf.xapian_available
      FileUtils.rm_rf File.join(RedmineDmsf.dmsf_index_database, RedmineDmsf.dmsf_stemming_lang)
      true
    else
      false
    end
  end
end
