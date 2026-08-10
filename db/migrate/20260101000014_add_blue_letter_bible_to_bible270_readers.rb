# frozen_string_literal: true

class AddBlueLetterBibleToBible270Readers < ActiveRecord::Migration[7.0]
  def change
    add_column :bible270_readers, :blue_letter_bible, :boolean, default: false, null: false
  end
end
