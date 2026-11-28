# frozen_string_literal: true

# Durable editor sessions and recovery files must outlive individual callbacks.
class CreateDmsfOnlyofficeSessions < ActiveRecord::Migration[7.0]
  def change
    create_table :dmsf_onlyoffice_sessions do |t|
      t.string :document_key, null: false, limit: 128
      t.bigint :dmsf_file_id, null: false
      t.bigint :source_revision_id
      t.string :source_filename
      t.string :source_content_type
      t.bigint :user_id
      t.string :mode, null: false, limit: 16
      t.string :state, null: false, default: 'active', limit: 32
      t.datetime :expires_at, null: false
      t.bigint :saved_revision_id
      t.text :last_error
      t.datetime :last_callback_at
      t.text :participants
      t.text :connected_users
      t.datetime :last_presence_at
      t.datetime :closed_at
      t.timestamps
    end
    add_index :dmsf_onlyoffice_sessions, :document_key, unique: true, name: 'idx_dmsf_oo_session_key'
    add_index :dmsf_onlyoffice_sessions, :dmsf_file_id, name: 'idx_dmsf_oo_session_file'
    add_index :dmsf_onlyoffice_sessions, %i[state expires_at], name: 'idx_dmsf_oo_session_active'
    add_index :dmsf_onlyoffice_sessions, :source_revision_id, name: 'idx_dmsf_oo_session_source'

    create_table :dmsf_onlyoffice_recoveries do |t|
      t.bigint :dmsf_onlyoffice_session_id, null: false
      t.string :kind, null: false, limit: 32
      t.string :checksum, null: false, limit: 64
      t.string :filename, null: false
      t.string :content_type, null: false
      t.bigint :size, null: false, default: 0
      t.text :reason
      t.string :state, null: false, default: 'pending', limit: 32
      t.bigint :restored_revision_id
      t.text :metadata
      t.timestamps
    end
    add_index :dmsf_onlyoffice_recoveries, %i[dmsf_onlyoffice_session_id kind checksum], unique: true,
              name: 'idx_dmsf_oo_recovery_content'
    add_index :dmsf_onlyoffice_recoveries, :state, name: 'idx_dmsf_oo_recovery_state'

    create_table :dmsf_onlyoffice_histories do |t|
      t.bigint :dmsf_file_revision_id, null: false
      t.bigint :source_revision_id
      t.text :metadata
      t.timestamps
    end
    add_index :dmsf_onlyoffice_histories, :dmsf_file_revision_id, unique: true,
              name: 'idx_dmsf_oo_history_revision'
    # Revision references deliberately have no restrictive foreign keys: retained
    # snapshots remain useful after an obsolete base revision has been pruned.
  end
end
