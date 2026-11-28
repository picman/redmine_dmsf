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

# ONLYOFFICE Operations migration
class CreateDmsfOnlyofficeOperations < ActiveRecord::Migration[7.0]
  def change
    create_table :dmsf_onlyoffice_operations do |t|
      t.string :request_key, null: false, limit: 64
      t.string :kind, null: false, limit: 20
      t.bigint :dmsf_file_id, null: false
      t.bigint :source_revision_id, null: false
      t.bigint :user_id, null: false
      t.bigint :folder_id
      t.bigint :result_file_id
      t.string :filename, null: false
      t.string :state, default: 'pending', null: false, limit: 20
      t.string :remote_key, limit: 128
      t.text :parameters
      t.text :last_error
      t.timestamps
    end
    add_index :dmsf_onlyoffice_operations, :request_key, unique: true
    add_index :dmsf_onlyoffice_operations, %i[dmsf_file_id user_id], name: 'idx_dmsf_oo_operations_file_user'
    add_index :dmsf_onlyoffice_operations, %i[source_revision_id state created_at],
              name: 'idx_dmsf_oo_operations_source'
  end
end
