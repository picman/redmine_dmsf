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
  Remove deleted items from all trash bins deleted before the given time (1 year by default).

  Available options:
    * age - How long ago were the items deleted in days

  Example:
    rake redmine:dmsf_prune_trash_bins RAILS_ENV="production"
    rake redmine:dmsf_prune_trash_bins age=30 RAILS_ENV="production"
END_DESC

namespace :redmine do
  task dmsf_prune_trash_bins: :environment do
    dmsf_prune_trash_bins = DmsfPruneTrashBins.new
    dmsf_prune_trash_bins.run
    puts 'done'
  rescue StandardError => e
    warn e.message
  end
end

# Clean up trash bins
class DmsfPruneTrashBins
  def initialize
    days = ENV.fetch('age', 365).to_i
    @timestamp = Time.current - (days * 24 * 60 * 60)
  end

  def run
    DmsfFile.prune @timestamp
    DmsfFolder.prune @timestamp
    DmsfLink.prune @timestamp
  end
end
