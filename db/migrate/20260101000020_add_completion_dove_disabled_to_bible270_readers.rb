# frozen_string_literal: true

class AddCompletionDoveDisabledToBible270Readers < ActiveRecord::Migration[7.0]
  def change
    add_column :bible270_readers, :completion_dove_disabled, :boolean, null: false, default: false
  end
end
