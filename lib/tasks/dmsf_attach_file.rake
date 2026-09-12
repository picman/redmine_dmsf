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

# A rake task to attach a file to a revision

namespace :kontron do
  desc <<-END_DESC
    Test task
      Attach a file with filename from DMSF < v5.0 to a revision where files are stored in Active Storage.
    Options:
      dry_run - no changes
    Example:
      bundle exec rake kontron:dmsf_attach_file RAILS_ENV="production"
      bundle exec rake kontron:dmsf_attach_file revision=1 file="/backup/dmsf/2016/10/161813092712_169435_Checklist.pdf" dry_run=1 RAILS_ENV="production"
  END_DESC

  task dmsf_attach_file: :environment do
    t = DmsfAttachFile.new
    t.test
    $stdout.puts 'Succeeded'
  rescue StandardError => e
    warn e.message
  end
end

# DmsfAttachFile
class DmsfAttachFile
  def initialize
    revision_id = ENV.fetch('revision', nil)
    raise StandardError, 'Enter a revision number' unless revision_id

    @revision = DmsfFileRevision.find(revision_id)

    @path = ENV.fetch('file', nil)
    raise StandardError, 'Enter a file path' unless @path

    raise(StandardError, 'Unexpected filename format') unless File.basename(@path) =~ /^\d+_\d+_(.+)/

    @filename = Regexp.last_match(1)
    @dry_run = ENV.fetch('dry_run', nil)
  end

  def test
    puts @filename
    return if @dry_run

    @revision.shared_file.attach(
      io: File.open(@path),
      filename: @filename
    )
    puts 'attached' if @revision.shared_file.attachment.save
  end
end
