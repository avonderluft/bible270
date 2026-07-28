# frozen_string_literal: true

class AddApprovalToBible270Comments < ActiveRecord::Migration[7.0]
  def change
    # Reflections are visible as soon as they are written; moderation is for
    # taking something down after the fact, not for gatekeeping every post.
    add_column :bible270_comments, :approved, :boolean, null: false, default: true
    add_column :bible270_comments, :moderated_at, :datetime
    add_index :bible270_comments, %i[approved day]
  end
end
