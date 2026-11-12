# frozen_string_literal: true

class AddAdminToBible270Readers < ActiveRecord::Migration[7.0]
  def change
    add_column :bible270_readers, :admin, :boolean, null: false, default: false
  end
end
