# frozen_string_literal: true

class AddRememberTokenToBible270Readers < ActiveRecord::Migration[7.0]
  # Lets a reader stay signed in across browser restarts. The cookie carries this
  # token alongside the reader id, so rotating it signs that reader out
  # everywhere — which a bare id in a cookie could not offer.
  def change
    add_column :bible270_readers, :remember_token, :string
    add_index :bible270_readers, :remember_token, name: 'idx_b270_readers_remember'
  end
end
