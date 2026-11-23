# frozen_string_literal: true

class AddPlus95EnabledToBible270PlanRuns < ActiveRecord::Migration[7.0]
  def change
    add_column :bible270_plan_runs, :plus95_enabled, :boolean, default: false, null: false
  end
end
