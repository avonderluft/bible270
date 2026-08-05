# frozen_string_literal: true

class AddMentionNoticesToBible270Readers < ActiveRecord::Migration[7.0]
  # Being emailed because someone typed your name is the sort of thing people
  # want to switch off, so it is a per-reader setting rather than a site-wide one.
  # Default true: a mention nobody hears about is not much use.
  def change
    add_column :bible270_readers, :notify_on_mention, :boolean, null: false, default: true
  end
end
