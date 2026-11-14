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

    def test_scripture_frame_migration_is_recognized
      migration = FakeMigration.new('CreateBible270ScriptureFrames', 20_260_101_000_027)

      status = build_reconciler(FakeContext.new([migration])).statuses.first

      assert status.complete?
      assert_equal :check_scripture_frames, Bible270::MigrationReconciler::CHECKS.fetch(migration.name)
    end

    def test_progress_sync_migration_is_recognized
      migration = FakeMigration.new('CreateBible270ProgressSync', 20_260_101_000_028)

      status = build_reconciler(FakeContext.new([migration])).statuses.first

      assert status.complete?, status.missing.join(', ')
      assert_equal :check_progress_sync, Bible270::MigrationReconciler::CHECKS.fetch(migration.name)
      assert_empty build_reconciler(FakeContext.new([migration], [migration.version])).statuses
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
      [%i[bible270_participations reader_id bible270_readers],
       %i[bible270_participations plan_run_id bible270_plan_runs],
       %i[bible270_checkoffs participation_id bible270_participations]].each do |table, column, target|
        rollback_schema_change do
          @connection.remove_foreign_key(table, target, column: column)

          assert_incomplete_run_schema
        end
      end
    end

    def test_reader_and_checkoff_foreign_keys_require_delete_cascades
      create_run_schema
      [%i[bible270_participations reader_id bible270_readers],
       %i[bible270_checkoffs participation_id bible270_participations]].each do |table, column, target|
        rollback_schema_change do
          @connection.remove_foreign_key(table, target, column: column)
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

  class MigrationReconcilerProgressSyncSchemaTest < Minitest::Test
    class IsolatedRecord < ActiveRecord::Base
      self.abstract_class = true
    end

    SYNC_TABLES = %i[bible270_progress_sync_links bible270_progress_sync_deliveries].freeze
    SYNC_FOREIGN_KEYS = [
      %i[bible270_progress_sync_links participation_id bible270_participations],
      %i[bible270_progress_sync_deliveries progress_sync_link_id bible270_progress_sync_links]
    ].freeze

    def setup
      IsolatedRecord.establish_connection(adapter: 'sqlite3', database: ':memory:')
      @connection = IsolatedRecord.connection
      @connection.create_table(:bible270_participations) do |table|
        table.integer :progress_sync_generation, null: false, default: 0
      end
      create_sync_schema
      migration = MigrationReconcilerTest::FakeMigration.new('CreateBible270ProgressSync', 20_260_101_000_028)
      @context = MigrationReconcilerTest::FakeContext.new([migration])
      @reconciler = Bible270::MigrationReconciler.new(connection: @connection, migration_context: @context)
    end

    def teardown
      IsolatedRecord.connection_pool.disconnect!
    end

    def test_complete_sync_schema_can_be_recorded
      status = @reconciler.statuses.first

      assert status.complete?, status.missing.join(', ')
      @reconciler.mark_applied!(status)
      assert_equal ['20260101000028'], @context.schema_migration.versions
    end

    def test_every_sync_table_is_required
      [:bible270_participations, *SYNC_TABLES].each do |table|
        rollback_schema_change do
          @connection.drop_table(table)

          assert_incomplete_sync_schema
          assert_includes @reconciler.check_progress_sync, "table #{table}"
        end
      end
    end

    def test_every_sync_column_is_required
      each_sync_column do |table, column|
        next if column.name == 'id'

        rollback_schema_change do
          @connection.remove_index(table, name: 'sync_active_destination') if table == :bible270_progress_sync_links && column.name == 'state'
          @connection.remove_column(table, column.name)

          assert_incomplete_sync_schema
          assert_includes @reconciler.check_progress_sync, "column #{table}.#{column.name}"
        end
      end
    end

    def test_sync_primary_key_columns_are_required
      columns = @connection.method(:columns)
      SYNC_TABLES.each do |table|
        @connection.stub(:columns, ->(name) { columns.call(name).reject { |column| name == table && column.name == 'id' } }) do
          assert_incomplete_sync_schema
          assert_includes @reconciler.check_progress_sync, "column #{table}.id"
        end
      end
    end

    def test_sync_primary_key_columns_require_integer_types_and_nonnullability
      columns = @connection.method(:columns)
      SYNC_TABLES.each do |table|
        { type: :string, null: true }.each do |attribute, value|
          @connection.stub(:columns, ->(name) {
            columns.call(name).map do |column|
              next column unless name == table && column.name == 'id'

              copy = column.dup
              copy.define_singleton_method(attribute) { value }
              copy
            end
          }) do
            assert_incomplete_sync_schema
            assert_includes @reconciler.check_progress_sync, "column #{table}.id #{attribute} #{attribute == :null ? false : :integer}"
          end
        end
      end
    end

    def test_every_sync_column_requires_its_type
      each_sync_column do |table, column|
        next if column.name == 'id'

        rollback_schema_change do
          replacement = column.type == :string ? :text : :string
          @connection.change_column(table, column.name, replacement)

          assert_incomplete_sync_schema
          assert(@reconciler.check_progress_sync.any? { |item| item.start_with?("column #{table}.#{column.name} type ") })
        end
      end
    end

    def test_every_sync_column_requires_its_nullability
      each_sync_column do |table, column|
        next if column.name == 'id'

        rollback_schema_change do
          @connection.change_column_null(table, column.name, !column.null)

          assert_incomplete_sync_schema
          assert_includes @reconciler.check_progress_sync, "column #{table}.#{column.name} null #{column.null}"
        end
      end
    end

    def test_every_sync_column_requires_its_default
      each_sync_column do |table, column|
        next if column.name == 'id'

        rollback_schema_change do
          default = case column.type
                    when :integer then 7
                    when :datetime then Time.utc(2000)
                    when :json then []
                    else 'unexpected'
                    end
          @connection.change_column_default(table, column.name, default)

          assert_incomplete_sync_schema
          assert(@reconciler.check_progress_sync.any? { |item| item.start_with?("column #{table}.#{column.name} default ") })
        end
      end
    end

    def test_zero_defaults_must_not_be_missing_or_malformed
      [%i[bible270_participations progress_sync_generation], %i[bible270_progress_sync_deliveries attempts]].each do |table, column|
        [nil, 'not-a-number', '0.5'].each do |default|
          rollback_schema_change do
            @connection.change_column_default(table, column, default.nil? ? nil : -> { @connection.quote(default) })

            assert_incomplete_sync_schema
          end
        end
      end
    end

    def test_expression_defaults_cannot_replace_absent_defaults
      @connection.change_column_default :bible270_progress_sync_links, :last_synced_at, -> { 'CURRENT_TIMESTAMP' }

      assert_incomplete_sync_schema
      assert_includes @reconciler.check_progress_sync, 'column bible270_progress_sync_links.last_synced_at default_function '
    end

    def test_postgresql_id_columns_require_bigint_width_and_allow_primary_key_sequences
      columns = @connection.method(:columns)
      ids = {
        bible270_progress_sync_links: %w[id participation_id remote_reader_id remote_participation_id],
        bible270_progress_sync_deliveries: %w[id progress_sync_link_id]
      }
      postgres_columns = ->(table, narrow: nil) {
        columns.call(table).map do |column|
          next column unless ids.fetch(table, []).include?(column.name)

          copy = column.dup
          copy.define_singleton_method(:limit) { narrow == [table, name] ? 4 : 8 }
          copy.define_singleton_method(:default_function) { "nextval('sync_id_seq'::regclass)" } if column.name == 'id'
          copy
        end
      }
      @connection.stub(:adapter_name, 'PostgreSQL') do
        @connection.stub(:columns, ->(table) { postgres_columns.call(table) }) do
          assert_empty @reconciler.check_progress_sync
        end
        ids.each do |table, names|
          names.each do |name|
            @connection.stub(:columns, ->(current) { postgres_columns.call(current, narrow: [table, name]) }) do
              assert_incomplete_sync_schema
              assert_includes @reconciler.check_progress_sync, "column #{table}.#{name} limit 8"
            end
          end
        end
      end
    end

    def test_every_sync_index_is_required
      SYNC_TABLES.each do |table|
        @connection.indexes(table).each do |index|
          rollback_schema_change do
            @connection.remove_index(table, name: index.name)

            assert_incomplete_sync_schema
          end
        end
      end
    end

    def test_nonunique_unconditional_or_wrong_column_indexes_cannot_replace_active_uniqueness
      [{ unique: false, where: "state = 'active'" }, { unique: true },
       { unique: true, where: "state = 'active'", columns: %i[destination participation_id] }].each do |options|
        rollback_schema_change do
          replace_active_index(**options)

          assert_incomplete_sync_schema
        end
      end
    end

    def test_equivalent_sqlite_predicates_are_accepted
      ["state='active'", "(state = 'active')", "((\"state\") = ('active'))", " ( ( state ) = ( 'active' ) ) "].each do |predicate|
        rollback_schema_change do
          replace_active_index(unique: true, where: predicate)

          assert_empty @reconciler.check_progress_sync, predicate
        end
      end
    end

    def test_equivalent_postgresql_predicate_metadata_is_accepted
      ["((state)::text = 'active'::text)", "((\"state\")::character varying = ('active'::character varying))",
       "(((state)::varchar)::text = (('active')::varchar)::text)"].each do |predicate|
        with_active_predicate_metadata(predicate) do
          assert_empty @reconciler.check_progress_sync, predicate
        end
      end
    end

    def test_other_sql_predicates_are_rejected_without_normalizing_literals_or_expressions
      ["state = 'paused'", "state = ' active '", "state = 'a(ctive)'", "state = 'Active'",
       "state IN ('active')", "state = 'active' OR state = 'paused'", "state = 'active' AND destination != ''",
       "(state = 'active') IS TRUE", "state COLLATE NOCASE = 'active'", "'active' = state", "state = 'active' AND 1 = 1"].each do |predicate|
        rollback_schema_change do
          replace_active_index(unique: true, where: predicate)

          assert_incomplete_sync_schema
        end
      end
      ["state::boolean = 'active'", "(state = 'active')::text", "\"STATE\" = 'active'", "state = 'active'::varchar(6)"].each do |predicate|
        with_active_predicate_metadata(predicate) { assert_incomplete_sync_schema }
      end
    end

    def test_a_leftover_unconditional_unique_index_conflicts_even_with_the_correct_partial_index
      [%i[participation_id destination], %i[destination participation_id]].each do |columns|
        rollback_schema_change do
          @connection.add_index :bible270_progress_sync_links, columns, unique: true, name: 'leftover_unique_destination'

          assert_incomplete_sync_schema
          assert_includes @reconciler.check_progress_sync,
                          'conflicting unconditional unique index bible270_progress_sync_links(participation_id, destination)'
        end
      end
    end

    def test_partial_indexes_cannot_replace_the_other_unconditional_sync_indexes
      SYNC_TABLES.each do |table|
        @connection.indexes(table).select { |index| index.where.nil? }.each do |index|
          rollback_schema_change do
            @connection.remove_index(table, name: index.name)
            @connection.add_index(table, index.columns, name: index.name, where: "#{index.columns.first} IS NOT NULL")

            assert_incomplete_sync_schema
          end
        end
      end
    end

    def test_every_sync_foreign_key_is_required
      SYNC_FOREIGN_KEYS.each do |table, column, target|
        rollback_schema_change do
          @connection.remove_foreign_key(table, target, column: column)

          assert_incomplete_sync_schema
        end
      end
    end

    def test_sync_foreign_keys_require_the_correct_target_and_delete_cascades
      @connection.create_table(:wrong_target)
      SYNC_FOREIGN_KEYS.each do |table, column, target|
        [{ to_table: target }, { to_table: target, on_delete: :nullify },
         { to_table: :wrong_target, on_delete: :cascade }].each do |options|
          rollback_schema_change do
            @connection.remove_foreign_key(table, target, column: column)
            @connection.add_foreign_key(table, options.fetch(:to_table), column: column, **options.except(:to_table))

            assert_incomplete_sync_schema
          end
        end
      end
    end

    def test_sync_foreign_keys_must_reference_the_id_primary_key
      SYNC_FOREIGN_KEYS.each do |table, column, target|
        rollback_schema_change do
          @connection.add_column target, :other_id, :bigint
          @connection.add_index target, :other_id, unique: true
          @connection.remove_foreign_key(table, target, column: column)
          @connection.add_foreign_key(table, target, column: column, primary_key: :other_id, on_delete: :cascade)

          assert_incomplete_sync_schema
        end
      end
    end

    def test_sync_foreign_keys_must_use_the_correct_source_column
      SYNC_FOREIGN_KEYS.each do |table, column, target|
        rollback_schema_change do
          @connection.add_column table, :other_id, :bigint
          @connection.remove_foreign_key(table, target, column: column)
          @connection.add_foreign_key(table, target, column: :other_id, on_delete: :cascade)

          assert_incomplete_sync_schema
        end
      end
    end

  private

    def assert_incomplete_sync_schema
      status = @reconciler.statuses.first
      refute status.complete?, 'Progress sync must not be marked on an incomplete or incompatible schema'
      assert_raises(ArgumentError) { @reconciler.mark_applied!(status) }
      assert_empty @context.schema_migration.versions
    end

    def rollback_schema_change
      @connection.transaction(requires_new: true) do
        yield
        raise ActiveRecord::Rollback
      end
    end

    def each_sync_column
      [:bible270_participations, *SYNC_TABLES].each do |table|
        @connection.columns(table).each do |column|
          next if table == :bible270_participations && column.name == 'id'

          yield table, column
        end
      end
    end

    def replace_active_index(columns: %i[participation_id destination], **)
      @connection.remove_index :bible270_progress_sync_links, name: 'sync_active_destination'
      @connection.add_index :bible270_progress_sync_links, columns, name: 'sync_active_destination', **
    end

    def with_active_predicate_metadata(predicate, &)
      indexes = @connection.method(:indexes)
      @connection.stub(:indexes, ->(table) {
        indexes.call(table).map do |index|
          next index unless index.name == 'sync_active_destination'

          copy = index.dup
          copy.define_singleton_method(:where) { predicate }
          copy
        end
      }, &)
    end

    def create_sync_schema
      @connection.create_table(:bible270_progress_sync_links) do |table|
        table.references :participation, null: false, foreign_key: { to_table: :bible270_participations, on_delete: :cascade }
        table.integer :source_generation, null: false
        table.string :destination, null: false
        table.string :destination_url, null: false
        table.bigint :remote_reader_id, null: false
        table.bigint :remote_participation_id, null: false
        table.integer :remote_generation, null: false
        table.string :remote_name, null: false
        table.string :email, null: false
        table.string :plan_fingerprint, null: false
        table.string :state, null: false, default: 'active'
        table.datetime :last_synced_at
        table.text :last_error
        table.integer :last_added
        table.integer :last_existing
        table.timestamps
      end
      @connection.add_index :bible270_progress_sync_links, %i[participation_id destination],
                            unique: true, where: "state = 'active'", name: 'sync_active_destination'
      @connection.create_table(:bible270_progress_sync_deliveries) do |table|
        table.references :progress_sync_link, null: false, foreign_key: { to_table: :bible270_progress_sync_links, on_delete: :cascade }
        table.json :readings, null: false
        table.integer :attempts, null: false, default: 0
        table.datetime :next_attempt_at, null: false
        table.datetime :locked_until
        table.string :claim_token
        table.datetime :delivered_at
        table.text :last_error
        table.timestamps
      end
      @connection.add_index :bible270_progress_sync_deliveries, %i[delivered_at next_attempt_at locked_until], name: 'sync_due'
    end
  end
end
