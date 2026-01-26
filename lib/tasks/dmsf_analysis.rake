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
  Try to add missing documents into Xapian full-text search index.

  Available options:
    * force - Analyze despite the fact that 'xapian:true' in the metadata

  Example:
    rake redmine:dmsf_analysis RAILS_ENV="production"
    rake redmine:dmsf_analysis force=1 RAILS_ENV="production"
END_DESC

namespace :redmine do
  task dmsf_analysis: :environment do
    force = ENV.fetch('force', nil)
    max_size = 1_024 * 1_024 * RedmineDmsf.dmsf_max_xapian_filesize
    scope = ActiveStorage::Blob.where([byte_size: ...max_size])
    count = scope.all.size
    scope.find_each.with_index do |blob, i|
      next if blob.audio? || blob.image? || blob.video?
      next if blob.metadata['xapian'] && !force

      blob.analyze
      print "\r#{i * 100 / count}%"
    end
    print "\r100%\n"
  end
end
