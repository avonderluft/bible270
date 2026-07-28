# frozen_string_literal: true

class CreateBible270SignInTokens < ActiveRecord::Migration[7.0]
  def change
    create_table :bible270_sign_in_tokens do |t|
      t.string   :email,        null: false
      t.string   :token_digest, null: false
      t.string   :display_name
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
    end

    add_index :bible270_sign_in_tokens, :token_digest, unique: true,
                                                       name: 'idx_b270_signin_tokens_digest'
    add_index :bible270_sign_in_tokens, %i[email created_at],
              name: 'idx_b270_signin_tokens_email'
  end
end
