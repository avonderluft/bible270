# frozen_string_literal: true

class AddNamesToBible270Readers < ActiveRecord::Migration[7.0]
  def change
    add_column :bible270_readers, :first_name, :string
    add_column :bible270_readers, :last_name, :string
    add_column :bible270_sign_in_tokens, :first_name, :string
    add_column :bible270_sign_in_tokens, :last_name, :string

    add_index :bible270_readers, %i[last_name first_name], name: 'idx_b270_readers_name'
  end
end
