# frozen_string_literal: true
class CreateBible270Checkoffs < ActiveRecord::Migration[7.0]
  def change
    create_table :bible270_checkoffs do |t|
      t.references :reader, null: false, index: true,
                   foreign_key: { to_table: :bible270_readers }
      t.integer :day,   null: false
      t.string  :track, null: false
      t.timestamps
    end
    add_index :bible270_checkoffs, %i[reader_id day track], unique: true,
              name: "idx_b270_checkoffs_unique"
    add_index :bible270_checkoffs, :day
  end
end
