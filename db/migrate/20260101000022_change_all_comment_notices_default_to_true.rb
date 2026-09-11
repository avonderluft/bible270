# frozen_string_literal: true

class ChangeAllCommentNoticesDefaultToTrue < ActiveRecord::Migration[7.0]
  def up
    change_column_default :bible270_readers, :notify_on_all_comments, from: false, to: true
  end

  def down
    change_column_default :bible270_readers, :notify_on_all_comments, from: true, to: false
  end
end
