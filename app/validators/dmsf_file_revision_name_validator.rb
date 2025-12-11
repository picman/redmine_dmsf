# frozen_string_literal: true

# Redmine plugin for Document Management System "Features"
#
# Vít Jonáš <vit.jonas@gmail.com>, Karel Pičman <karel.picman@kontron.com>
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

# File name validator
class DmsfFileRevisionNameValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    # Check name/title uniqueness
    DmsfFile
      .visible
      .where(project_id: record.dmsf_file.project_id, dmsf_folder_id: record.dmsf_file.dmsf_folder_id)
      .where.not(id: record.dmsf_file_id)
      .find_each do |dmsf_file|
        if dmsf_file.name == value
          record.errors.add attribute, :taken
          break
        end
      end
  end
end
