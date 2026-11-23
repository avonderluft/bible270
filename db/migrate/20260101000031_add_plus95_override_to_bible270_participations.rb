# frozen_string_literal: true

class AddPlus95OverrideToBible270Participations < ActiveRecord::Migration[7.0]
  def change
    # nil inherits the plan run's default; true opts into +95, false uses 270.
    add_column :bible270_participations, :plus95_override, :boolean, default: nil, null: true
  end
end
