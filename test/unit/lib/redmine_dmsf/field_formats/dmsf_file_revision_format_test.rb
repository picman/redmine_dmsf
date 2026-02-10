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

require File.expand_path('../../../../../test_helper', __FILE__)

# Tests the DMS file revision custom field
class DmsfFileRevisionFormatTest < RedmineDmsf::Test::FieldFormatTest
  fixtures :dmsf_locks, :dmsf_workflows, :dmsf_folders, :dmsf_files, :dmsf_file_revisions

  def setup
    super
    User.current = User.find_by(login: 'jsmith')
    manager = Role.find_by(name: 'Manager')
    manager.add_permission!(:view_dmsf_files)
    project = Project.find_by(id: 1)
    project.enable_module!(:dmsf)
  end

  def test_field_with_url_pattern_should_link_value
    field = IssueCustomField.new(field_format: 'dmsf_file_revision')
    revision_id = 1
    formatted = field.format.formatted_value(self, field, revision_id, Issue.new, true)
    html = <<~HTML
      <a target="_blank" rel="noopener" class="icon icon-file" title="Some file :-)"
        data-downloadurl="text/plain:test.txt:/dmsf/files/1/test.txt?download=1"
        href="/dmsf/files/1/test.txt?download=1"><svg class="s18 icon-svg"
          aria-hidden="true"><use href="/icons.svg#icon--text-plain"></use>
        </svg><span class="icon-label">test.txt</span></a>
    HTML
    doc = Nokogiri::HTML.fragment(html)
    use = doc.at_css('use')
    assert_match %r{/icons\.svg#icon--text-plain}, use['href']
    assert formatted.html_safe?
  end
end
