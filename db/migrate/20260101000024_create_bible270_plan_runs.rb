# frozen_string_literal: true

class CreateBible270PlanRuns < ActiveRecord::Migration[7.0]
  # Deliberately independent of application models and their enrollment callbacks.
  class Run < ActiveRecord::Base
    self.table_name = 'bible270_plan_runs'
  end

  def up
    create_table :bible270_plan_runs do |t|
      t.boolean :current
      t.date :start_date
      t.datetime :archived_at
      t.timestamps
    end
    # Archived rows use NULL, not false: a unique nullable marker permits history
    # while enforcing at most one current run on both SQLite and PostgreSQL.
    add_index :bible270_plan_runs, :current, unique: true

    create_table :bible270_participations do |t|
      t.references :reader, null: false, foreign_key: { to_table: :bible270_readers, on_delete: :cascade }
      t.references :plan_run, null: false, foreign_key: { to_table: :bible270_plan_runs }
      t.boolean :active, null: false, default: true
      t.datetime :joined_at, null: false
      t.date :started_on
      t.date :archived_on
      t.date :frozen_start_date
      t.timestamps
    end
    add_index :bible270_participations, %i[reader_id plan_run_id], unique: true,
                                                                   name: 'idx_b270_participations_reader_run'

    Run.reset_column_information
    run = Run.create!(current: true)
    execute <<~SQL.squish
      INSERT INTO bible270_participations
        (reader_id, plan_run_id, active, joined_at, started_on, created_at, updated_at)
      SELECT id, #{connection.quote(run.id)}, #{connection.quote(true)}, created_at,
             started_on, created_at, updated_at FROM bible270_readers
    SQL

    add_reference :bible270_checkoffs, :participation,
                  foreign_key: { to_table: :bible270_participations, on_delete: :cascade }
    execute <<~SQL.squish
      UPDATE bible270_checkoffs SET participation_id = (
        SELECT id FROM bible270_participations
        WHERE bible270_participations.reader_id = bible270_checkoffs.reader_id
          AND bible270_participations.plan_run_id = #{connection.quote(run.id)}
      )
    SQL
    change_column_null :bible270_checkoffs, :participation_id, false
    remove_index :bible270_checkoffs, name: 'idx_b270_checkoffs_part_unique'
    add_index :bible270_checkoffs, %i[participation_id day track part], unique: true,
                                                                        name: 'idx_b270_checkoffs_part_unique'
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Multiple runs cannot be collapsed without losing progress history'
  end
end
