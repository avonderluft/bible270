# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  require_relative '../db/migrate/20260101000031_add_plus95_override_to_bible270_participations'

  class Plus95OverrideMigrationTest < Minitest::Test
    class IsolatedRecord < ActiveRecord::Base
      self.abstract_class = true
    end

    def setup
      IsolatedRecord.establish_connection(adapter: 'sqlite3', database: ':memory:')
      @connection = IsolatedRecord.connection
      @connection.create_table(:bible270_participations) { |table| table.integer :plan_run_id, null: false }
      @connection.execute('INSERT INTO bible270_participations (plan_run_id) VALUES (1)')
      @migration = AddPlus95OverrideToBible270Participations.new
      @migration.verbose = false
    end

    def teardown
      IsolatedRecord.connection_pool.disconnect!
    end

    def test_existing_and_new_participations_inherit_unless_explicitly_overridden
      @migration.exec_migration(@connection, :up)
      @connection.execute('INSERT INTO bible270_participations (plan_run_id) VALUES (1)')
      @connection.execute('INSERT INTO bible270_participations (plan_run_id, plus95_override) VALUES (1, TRUE), (1, FALSE)')
      column = @connection.columns(:bible270_participations).find { |candidate| candidate.name == 'plus95_override' }

      assert_equal :boolean, column.type
      assert column.null
      assert_nil column.default
      assert_equal [nil, nil, 1, 0], @connection.select_values('SELECT plus95_override FROM bible270_participations ORDER BY id')
    end

    def test_rollback_removes_the_override_without_removing_participations
      @migration.exec_migration(@connection, :up)
      @migration.exec_migration(@connection, :down)

      refute @connection.column_exists?(:bible270_participations, :plus95_override)
      assert_equal [1], @connection.select_values('SELECT plan_run_id FROM bible270_participations')
    end
  end
end
