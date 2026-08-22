# frozen_string_literal: true

class AddMentionNoticesToBible270Readers < ActiveRecord::Migration[7.0]
  # Replies and explicit mentions share one preference: both are direct responses
  # from another reader, and separate switches would add needless complexity.
  # Default true so existing conversations remain connected.
  def change
    add_column :bible270_readers, :notify_on_mention, :boolean, null: false, default: true
  end
end
