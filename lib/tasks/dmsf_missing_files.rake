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

desc <<~END_DESC
  Identify documents without a physical file in the file system present

  Example:
    rake redmine:dmsf_missing_files RAILS_ENV="production"
END_DESC

namespace :redmine do
  task dmsf_missing_files: :environment do
    dmsf_missing_files = DmsfMissingFiles.new
    dmsf_missing_files.run
    puts 'done'
  end
end

# Search for missing files
class DmsfMissingFiles
  def run
    scope = DmsfFile.visible
    n = scope.all.size
    i = 0
    e = 0
    scope.find_each do |dmsf_file|
      i += 1
      print "\r#{i * 100 / n}%"
      rev = dmsf_file.last_revision
      unless rev
        print "\rdmsf_file #{dmsf_file.id} has no revision\n"
        e += 1
        next
      end
      file = rev.file
      unless file.attached?
        print "\rdmsf_file #{dmsf_file.id}, dmsf_file_revision #{rev.id} has no shared file attached\n"
        e += 1
        next
      end
    end
    print "\r100%"
    print "\n#{e} of #{n} files are missing\n"
  end
end
