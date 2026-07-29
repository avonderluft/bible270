# frozen_string_literal: true

class CreateBible270Settings < ActiveRecord::Migration[7.0]
  def change
    # A tiny key/value store for state an admin can change at runtime. Closing a
    # run to new readers can't live in config, since that would need a deploy.
    create_table :bible270_settings do |t|
      t.string :key,   null: false
      t.string :value
      t.timestamps
    end

    add_index :bible270_settings, :key, unique: true, name: 'idx_b270_settings_key'
  end
end
