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

require File.expand_path('../../test_helper', __FILE__)

# Upload tests
class DmsfUploadTest < RedmineDmsf::Test::UnitTest
  def test_initialize
    with_settings plugin_redmine_dmsf: { 'empty_minor_version_by_default' => '1' } do
      upload = DmsfUpload.new(@project1, nil)
      assert_equal 1, upload.major_version
      assert_nil upload.minor_version
    end
    with_settings plugin_redmine_dmsf: { 'empty_minor_version_by_default' => nil } do
      upload = DmsfUpload.new(@project1, nil)
      assert_equal 0, upload.major_version
      assert_equal 0, upload.minor_version
    end
  end
end
