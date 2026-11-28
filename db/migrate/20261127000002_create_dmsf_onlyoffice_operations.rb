# frozen_string_literal: true

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
