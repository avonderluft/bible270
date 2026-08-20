# frozen_string_literal: true

class AddReflectionsSeenAtToBible270Readers < ActiveRecord::Migration[7.0]
  def change
    add_column :bible270_readers, :reflections_seen_at, :datetime
  end
end
