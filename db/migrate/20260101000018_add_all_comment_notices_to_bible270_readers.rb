# frozen_string_literal: true

class AddAllCommentNoticesToBible270Readers < ActiveRecord::Migration[7.0]
  def change
    add_column :bible270_readers, :notify_on_all_comments, :boolean, null: false, default: false
  end
end
