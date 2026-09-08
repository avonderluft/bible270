# frozen_string_literal: true

class AddBodyFormatToBible270Comments < ActiveRecord::Migration[7.0]
  def up
    add_column :bible270_comments, :body_format, :string, null: false, default: 'plain'
  end

  def down
    remove_column :bible270_comments, :body_format
  end
end
