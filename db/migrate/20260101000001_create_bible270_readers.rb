# frozen_string_literal: true
class CreateBible270Readers < ActiveRecord::Migration[7.0]
  def change
    create_table :bible270_readers do |t|
      t.string  :display_name, null: false
      t.string  :email
      t.string  :avatar_url
      t.string  :provider
      t.string  :uid
      t.references :owner, polymorphic: true, index: true
      t.date    :started_on
      t.timestamps
    end
    add_index :bible270_readers, %i[provider uid], unique: true,
              name: "idx_b270_readers_provider_uid"
  end
end
