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
    $stdout.puts "It could be a very long process. Be patient...\n"
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
        next if r.dmsf_file.project.id != 3886 # Dry run

        if i.zero?
          r.shared_file.attach(
            io: File.open(path),
            filename: r.name,
            content_type: r.mime_type,
            identify: false
          )
          # Remove the original file
          FileUtils.rm path
          key = r.shared_file.blob.key
          $stdout.puts "#{path} => #{File.join(key[0..1], key[2..3], key)} (#{r.shared_file.blob.filename})"
        else
          # The other revisions should have set the source revision
          unless r.source_dmsf_file_revision_id
            warn "r#{r.id}.source_dmsf_file_revision_id is null"
          end
        end
      end
    end
    $stdout.puts 'Done'
  end

  # Active Storage -> File system
  def down
    n = DmsfFileRevision.all.size
    $stdout.puts "#{n} revisions found. It could be a very long process. Be patient...\n"
    DmsfFileRevision.find_each.with_index do |r, i|
      $stdout.print "\r#{i * 100 / n}%"
      next unless r.shared_file.attached?
      next if r.dmsf_file.project.id != 3886 # Dry run

      new_path = r.disk_file(search_if_not_exists: false)
      unless File.exist?(new_path)
        r.shared_file.open do |f|
          FileUtils.mv f.path, new_path
        end
      end
      # Remove the original file
      r.shared_file.purge
    end
    $stdout.puts 'Done'
  end
end
