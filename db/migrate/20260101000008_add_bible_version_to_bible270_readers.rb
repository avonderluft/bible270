# frozen_string_literal: true

class AddBibleVersionToBible270Readers < ActiveRecord::Migration[7.0]
  def change
    # Null means "use whatever the site default is", so changing
    # config.bible_version moves everyone who hasn't chosen for themselves.
    add_column :bible270_readers, :bible_version, :string
  end
end
