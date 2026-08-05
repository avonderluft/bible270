# frozen_string_literal: true

class AddParentToBible270Comments < ActiveRecord::Migration[7.0]
  # Replies. One level only: a reply cannot itself be replied to, which keeps the
  # rendering and the moderation story simple — a thread is a reflection and the
  # answers to it, not a tree.
  def change
    add_reference :bible270_comments, :parent, null: true, index: { name: 'idx_b270_comments_parent' },
                                               foreign_key: { to_table: :bible270_comments }
  end
end
