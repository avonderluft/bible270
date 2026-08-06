# frozen_string_literal: true

class CreateBible270Likes < ActiveRecord::Migration[7.0]
  def change
    create_table :bible270_likes do |t|
      t.references :reader, null: false, index: false,
                            foreign_key: { to_table: :bible270_readers }
      t.references :comment, null: false, index: false,
                             foreign_key: { to_table: :bible270_comments }
      t.timestamps
    end

    # One like per reader per reflection, enforced by the database as well as the
    # model: a double-tap should not become two hearts.
    add_index :bible270_likes, %i[reader_id comment_id], unique: true,
                               name: 'idx_b270_likes_unique'
    # Reading a thread asks for a comment's likes, so that is the index that earns
    # its keep.
    add_index :bible270_likes, :comment_id, name: 'idx_b270_likes_comment'
  end
end
