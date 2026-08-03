# frozen_string_literal: true

class AddOnlyofficeKeyToDmsfFileRevisions < ActiveRecord::Migration[7.0]
  def change
    add_column :dmsf_file_revisions, :onlyoffice_key, :string, limit: 128
    add_index :dmsf_file_revisions, :onlyoffice_key, unique: true
  end
end
