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

require File.expand_path('../../../../test_helper', __FILE__)
require File.expand_path('../../../../../lib/redmine_dmsf/dmsf_zip', __FILE__)

# Plugin tests
class DmsfZipTest < RedmineDmsf::Test::HelperTest
  def setup
    super
    @zip = RedmineDmsf::DmsfZip::Zip.new
    @dmsf_file1 = DmsfFile.find(1)
    @dmsf_folder2 = DmsfFolder.find(2)
    set_fixtures_attachments_directory
    @attachment6 = Attachment.find(6)
  end

  def test_add_dmsf_file
    @zip.add_dmsf_file @dmsf_file1
    assert_equal 1, @zip.dmsf_files.size
    zip_file = @zip.finish
    Zip::File.open(zip_file) do |file|
      file.each do |entry|
        assert_equal @dmsf_file1.last_revision.name, entry.name
      end
    end
  end

  def test_read
    @zip.add_dmsf_file @dmsf_file1
    assert_not_empty @zip.read
  end

  def test_finish
    @zip.add_dmsf_file @dmsf_file1
    zip_file = @zip.finish
    assert File.exist?(zip_file)
  end

  def test_close
    @zip.add_dmsf_file @dmsf_file1
    assert @zip.close
  end
end
