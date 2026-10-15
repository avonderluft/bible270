# frozen_string_literal: true

class AddDisplayModeToBible270Readers < ActiveRecord::Migration[7.0]
  def change
    add_column :bible270_readers, :display_mode, :string, null: false, default: 'system'
  end
end
