# frozen_string_literal: true

require 'test_helper'
require 'bible270/migration_reconciler'

if RAILS_LOADED
  class MigrationReconcilerTest < Minitest::Test
    FakeMigration = Struct.new(:name, :version)

    class FakeSchemaMigration
      attr_reader :versions

      def initialize
        @versions = []
      end

      def create_version(version)
        versions << version
      end
    end

    class FakeContext
      attr_reader :migrations, :schema_migration

      def initialize(migrations, applied = [])
        @migrations = migrations
        @applied = applied
        @schema_migration = FakeSchemaMigration.new
      end

      define_method(:get_all_versions) { @applied }
    end

    def test_current_database_factory_uses_the_apps_migration_context
      reconciler = Bible270::MigrationReconciler.for_current_database

      assert_empty reconciler.statuses
    end

    def test_every_known_migration_matches_the_current_schema
      reconciler = build_reconciler(FakeContext.new([]))

      Bible270::MigrationReconciler::CHECKS.each do |name, check|
        assert_empty reconciler.public_send(check), "#{name} does not match the migrated test schema"
      end
    end

    def test_daily_reminder_migration_is_recognized
      migration = FakeMigration.new('AddDailyRemindersToBible270Readers', 20_260_101_000_016)

      status = build_reconciler(FakeContext.new([migration])).statuses.first

      assert status.complete?
      assert_equal :check_daily_reminders,
                   Bible270::MigrationReconciler::CHECKS.fetch(migration.name)
    end

    def test_reflections_seen_migration_is_recognized
      migration = FakeMigration.new('AddReflectionsSeenAtToBible270Readers', 20_260_101_000_017)

      status = build_reconciler(FakeContext.new([migration])).statuses.first

      assert status.complete?
      assert_equal :check_reflections_seen_at,
                   Bible270::MigrationReconciler::CHECKS.fetch(migration.name)
    end

    def test_all_comment_notices_migration_is_recognized
      migration = FakeMigration.new('AddAllCommentNoticesToBible270Readers', 20_260_101_000_018)

      status = build_reconciler(FakeContext.new([migration])).statuses.first

      assert status.complete?
      assert_equal :check_all_comment_notices,
                   Bible270::MigrationReconciler::CHECKS.fetch(migration.name)
    end

    def test_bible_com_default_migration_is_recognized
      migration = FakeMigration.new('ChangePassageSourceDefaultToBibleCom', 20_260_101_000_019)

      status = build_reconciler(FakeContext.new([migration])).statuses.first

      assert status.complete?
      assert_equal :check_passage_source_default,
                   Bible270::MigrationReconciler::CHECKS.fetch(migration.name)
    end

    def test_completion_dove_preference_migration_is_recognized
      migration = FakeMigration.new('AddCompletionDoveDisabledToBible270Readers', 20_260_101_000_020)

      status = build_reconciler(FakeContext.new([migration])).statuses.first

      assert status.complete?
      assert_equal :check_completion_dove_disabled,
                   Bible270::MigrationReconciler::CHECKS.fetch(migration.name)
    end

    def test_comment_body_format_migration_is_recognized
      migration = FakeMigration.new('AddBodyFormatToBible270Comments', 20_260_101_000_021)

      status = build_reconciler(FakeContext.new([migration])).statuses.first

      assert status.complete?
      assert_equal :check_comment_body_format,
                   Bible270::MigrationReconciler::CHECKS.fetch(migration.name)
    end

    def test_all_comment_notices_default_migration_is_recognized
      migration = FakeMigration.new('ChangeAllCommentNoticesDefaultToTrue', 20_260_101_000_022)

      status = build_reconciler(FakeContext.new([migration])).statuses.first

      assert status.complete?
      assert_equal :check_all_comment_notices_default,
                   Bible270::MigrationReconciler::CHECKS.fetch(migration.name)
    end

    def test_display_mode_migration_is_recognized
      migration = FakeMigration.new('AddDisplayModeToBible270Readers', 20_260_101_000_023)

      status = build_reconciler(FakeContext.new([migration])).statuses.first

      assert status.complete?
      assert_equal :check_display_mode, Bible270::MigrationReconciler::CHECKS.fetch(migration.name)
    end

    def test_plan_runs_migration_is_recognized
      migration = FakeMigration.new('CreateBible270PlanRuns', 20_260_101_000_024)

      status = build_reconciler(FakeContext.new([migration])).statuses.first

      assert status.complete?
      assert_equal :check_plan_runs, Bible270::MigrationReconciler::CHECKS.fetch(migration.name)
    end

    def test_admin_migration_is_recognized
      migration = FakeMigration.new('AddAdminToBible270Readers', 20_260_101_000_025)

      status = build_reconciler(FakeContext.new([migration])).statuses.first

      assert status.complete?
      assert_equal :check_admin, Bible270::MigrationReconciler::CHECKS.fetch(migration.name)
    end

    def test_run_revert_migration_is_recognized
      migration = FakeMigration.new('AddRevertToBible270PlanRuns', 20_260_101_000_026)

      status = build_reconciler(FakeContext.new([migration])).statuses.first

      assert status.complete?
      assert_equal :check_run_revert, Bible270::MigrationReconciler::CHECKS.fetch(migration.name)
    end

    def test_only_pending_bible270_migrations_are_assessed
      migrations = [
        FakeMigration.new('CreateBible270Readers', 101),
        FakeMigration.new('CreateBible270Comments', 102),
        FakeMigration.new('CreateUnrelatedTable', 103)
      ]
      context = FakeContext.new(migrations, [102])

      statuses = build_reconciler(context).statuses
      names = statuses.map { |status| status.migration.name }

      assert_equal ['CreateBible270Readers'], names
      assert statuses.first.complete?
    end

    def test_a_complete_migration_can_be_recorded
      migration = FakeMigration.new('CreateBible270Readers', 20_260_730_030_530)
      context = FakeContext.new([migration])
      reconciler = build_reconciler(context)

      reconciler.mark_applied!(reconciler.statuses.first)

      assert_equal ['20260730030530'], context.schema_migration.versions
    end

  private

    def build_reconciler(context)
      Bible270::MigrationReconciler.new(
        connection: ActiveRecord::Base.connection,
        migration_context: context
      )
    end
  end

  class MigrationReconcilerSchemaTest < Minitest::Test
    class IsolatedRecord < ActiveRecord::Base
      self.abstract_class = true
    end

    def setup
      IsolatedRecord.establish_connection(adapter: 'sqlite3', database: ':memory:')
      @connection = IsolatedRecord.connection
      @connection.create_table(:bible270_readers)
      @connection.create_table(:bible270_checkoffs) do |table|
        table.references :reader, null: false, foreign_key: { to_table: :bible270_readers }
        table.integer :day
        table.string :track
        table.integer :part, null: false, default: 0
        table.timestamps
      end
      @connection.add_index :bible270_checkoffs, %i[reader_id day track part], unique: true,
                                                                               name: 'idx_b270_checkoffs_part_unique'
      migrations = [
        MigrationReconcilerTest::FakeMigration.new('AddPartToBible270Checkoffs', 20_260_101_000_009),
        MigrationReconcilerTest::FakeMigration.new('CreateBible270PlanRuns', 20_260_101_000_024),
        MigrationReconcilerTest::FakeMigration.new('AddAdminToBible270Readers', 20_260_101_000_025)
      ]
      @context = MigrationReconcilerTest::FakeContext.new(migrations)
      @reconciler = Bible270::MigrationReconciler.new(connection: @connection, migration_context: @context)
    end

    def teardown
      IsolatedRecord.connection_pool.disconnect!
    end

    def test_legacy_schema_marks_only_the_parts_migration
      parts, runs, admin = @reconciler.statuses

      assert parts.complete?
      @reconciler.mark_applied!(parts)
      refute runs.complete?
      refute admin.complete?
      assert_raises(ArgumentError) { @reconciler.mark_applied!(runs) }
      assert_raises(ArgumentError) { @reconciler.mark_applied!(admin) }
      assert_equal ['20260101000009'], @context.schema_migration.versions
    end

    def test_modern_schema_can_record_both_old_and_new_migrations
      create_run_schema
      @connection.add_column :bible270_readers, :admin, :boolean, null: false, default: false

      @reconciler.statuses.each do |status|
        assert status.complete?, status.missing.join(', ')
        @reconciler.mark_applied!(status)
      end

      assert_equal %w[20260101000009 20260101000024 20260101000025], @context.schema_migration.versions
    end

    def test_parts_migration_requires_the_part_column
      @connection.remove_column :bible270_checkoffs, :part

      refute @reconciler.statuses.first.complete?
      assert_includes @reconciler.check_checkoff_parts, 'column bible270_checkoffs.part'
    end

    def test_parts_migration_requires_a_full_unique_index
      @connection.remove_index :bible270_checkoffs, name: 'idx_b270_checkoffs_part_unique'
      @connection.add_index :bible270_checkoffs, %i[reader_id day track part]

      refute @reconciler.statuses.first.complete?
    end

    def test_modern_index_alone_does_not_prove_either_migration_is_complete
      @connection.add_column :bible270_checkoffs, :participation_id, :bigint
      @connection.remove_index :bible270_checkoffs, name: 'idx_b270_checkoffs_part_unique'
      @connection.add_index :bible270_checkoffs, %i[participation_id day track part], unique: true

      assert_incomplete_run_schema
    end

    def test_missing_run_or_participation_table_is_incomplete
      create_run_schema
      %i[bible270_plan_runs bible270_participations].each do |table|
        rollback_schema_change do
          @connection.drop_table(table)

          assert_incomplete_run_schema
        end
      end
    end

    def test_every_run_schema_column_is_required
      create_run_schema
      {
        bible270_plan_runs: %i[current start_date archived_at created_at updated_at],
        bible270_participations: %i[reader_id plan_run_id active joined_at started_on archived_on frozen_start_date created_at updated_at],
        bible270_checkoffs: %i[participation_id part]
      }.each do |table, columns|
        columns.each do |column|
          rollback_schema_change do
            @connection.remove_column(table, column)

            assert_incomplete_run_schema
          end
        end
      end
    end

    def test_every_run_schema_index_is_required
      create_run_schema
      %i[bible270_plan_runs bible270_participations bible270_checkoffs].each do |table|
        @connection.indexes(table).each do |index|
          next if index.columns == ['reader_id'] && table == :bible270_checkoffs

          rollback_schema_change do
            @connection.remove_index(table, name: index.name)

            assert_incomplete_run_schema
          end
        end
      end
    end

    def test_nonunique_or_partial_indexes_cannot_replace_run_uniqueness
      create_run_schema
      {
        bible270_plan_runs: %i[current],
        bible270_participations: %i[reader_id plan_run_id],
        bible270_checkoffs: %i[participation_id day track part]
      }.each do |table, columns|
        [{ unique: false }, { unique: true, where: "#{columns.first} IS NOT NULL" }].each do |options|
          rollback_schema_change do
            index = @connection.indexes(table).find { |candidate| candidate.columns == columns.map(&:to_s) }
            @connection.remove_index(table, name: index.name)
            @connection.add_index(table, columns, **options)

            assert_incomplete_run_schema
          end
        end
      end
    end

    def test_every_run_foreign_key_is_required
      create_run_schema
      {
        bible270_participations: %i[reader_id plan_run_id],
        bible270_checkoffs: %i[participation_id]
      }.each do |table, columns|
        columns.each do |column|
          rollback_schema_change do
            @connection.remove_foreign_key(table, column: column)

            assert_incomplete_run_schema
          end
        end
      end
    end

    def test_reader_and_checkoff_foreign_keys_require_delete_cascades
      create_run_schema
      [%i[bible270_participations reader_id bible270_readers],
       %i[bible270_checkoffs participation_id bible270_participations]].each do |table, column, target|
        rollback_schema_change do
          @connection.remove_foreign_key(table, column: column)
          @connection.add_foreign_key(table, target, column: column)

          assert_incomplete_run_schema
        end
      end
    end

    def test_run_column_nullability_and_defaults_are_required
      create_run_schema
      [[:bible270_plan_runs, :current, false],
       [:bible270_participations, :reader_id, true],
       [:bible270_participations, :plan_run_id, true],
       [:bible270_participations, :active, true],
       [:bible270_participations, :joined_at, true],
       [:bible270_checkoffs, :participation_id, true]].each do |table, column, nullable|
        rollback_schema_change do
          @connection.change_column_null(table, column, nullable)

          assert_incomplete_run_schema
        end
      end
      rollback_schema_change do
        @connection.change_column_default :bible270_participations, :active, false

        assert_incomplete_run_schema
      end
    end

    def test_run_schema_rejects_a_leftover_reader_scoped_unique_index
      create_run_schema
      @connection.add_index :bible270_checkoffs, %i[reader_id day track part], unique: true
      status = @reconciler.statuses[1]

      refute status.complete?
      assert_raises(ArgumentError) { @reconciler.mark_applied!(status) }
    end

    def test_admin_requires_boolean_type_nonnull_and_false_default
      [[:boolean, { null: true, default: false }],
       [:boolean, { null: false, default: true }],
       [:boolean, { null: false }],
       [:string, { null: false, default: 'false' }]].each do |type, options|
        rollback_schema_change do
          @connection.add_column :bible270_readers, :admin, type, **options
          status = @reconciler.statuses.last

          refute status.complete?
          assert_raises(ArgumentError) { @reconciler.mark_applied!(status) }
        end
      end
    end

  private

    def assert_incomplete_run_schema
      @reconciler.statuses.first(2).each do |status|
        refute status.complete?, "#{status.migration.name} must not be marked on an incomplete run schema"
        assert_raises(ArgumentError) { @reconciler.mark_applied!(status) }
      end
      assert_empty @context.schema_migration.versions
    end

    def rollback_schema_change
      @connection.transaction(requires_new: true) do
        yield
        raise ActiveRecord::Rollback
      end
    end

    def create_run_schema
      @connection.create_table(:bible270_plan_runs) do |table|
        table.boolean :current
        table.date :start_date
        table.datetime :archived_at
        table.timestamps
      end
      @connection.add_index :bible270_plan_runs, :current, unique: true
      @connection.create_table(:bible270_participations) do |table|
        table.references :reader, null: false, foreign_key: { to_table: :bible270_readers, on_delete: :cascade }
        table.references :plan_run, null: false, foreign_key: { to_table: :bible270_plan_runs }
        table.boolean :active, null: false, default: true
        table.datetime :joined_at, null: false
        table.date :started_on
        table.date :archived_on
        table.date :frozen_start_date
        table.timestamps
      end
      @connection.add_index :bible270_participations, %i[reader_id plan_run_id], unique: true,
                                                                                 name: 'idx_b270_participations_reader_run'
      @connection.add_reference :bible270_checkoffs, :participation, null: false,
                                                                     foreign_key: { to_table: :bible270_participations, on_delete: :cascade }
      @connection.remove_index :bible270_checkoffs, name: 'idx_b270_checkoffs_part_unique'
      @connection.add_index :bible270_checkoffs, %i[participation_id day track part], unique: true,
                                                                                      name: 'idx_b270_checkoffs_part_unique'
    end
  end
end
