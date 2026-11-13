# frozen_string_literal: true

class AddRevertToBible270PlanRuns < ActiveRecord::Migration[7.0]
  def change
    add_column :bible270_plan_runs, :restart_snapshot, :json
    add_column :bible270_plan_runs, :reverted_at, :datetime
  end
end
