# frozen_string_literal: true
class CreateBible270Comments < ActiveRecord::Migration[7.0]
  def change
    create_table :bible270_comments do |t|
      t.references :reader, null: false, index: true,
                   foreign_key: { to_table: :bible270_readers }
      t.integer :day,   null: false
      t.string  :track
      t.text    :body,  null: false
      t.timestamps
    end
    add_index :bible270_comments, %i[day created_at]
  end
end
