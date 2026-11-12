# frozen_string_literal: true

class CreateBible270ScriptureFrames < ActiveRecord::Migration[7.0]
  def change
    create_table :bible270_scripture_frames do |t|
      t.string :reference, limit: 200, null: false
      t.text :text, null: false
      t.string :translation, limit: 40, null: false, default: 'NASB95'
      t.string :attribution, limit: 500
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end

    add_index :bible270_scripture_frames, :enabled
  end
end
