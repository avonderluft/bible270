# frozen_string_literal: true

class AddPassageSourceToBible270Readers < ActiveRecord::Migration[7.0]
  def up
    add_column :bible270_readers, :passage_source, :string, default: 'bible_gateway', null: false

    return unless column_exists?(:bible270_readers, :blue_letter_bible)

    execute <<~SQL.squish
      UPDATE bible270_readers
      SET passage_source = 'blue_letter_bible'
      WHERE blue_letter_bible = TRUE
    SQL
    remove_column :bible270_readers, :blue_letter_bible
  end

  def down
    add_column :bible270_readers, :blue_letter_bible, :boolean, default: false, null: false
    execute <<~SQL.squish
      UPDATE bible270_readers
      SET blue_letter_bible = TRUE
      WHERE passage_source = 'blue_letter_bible'
    SQL
    remove_column :bible270_readers, :passage_source
  end
end
