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
end
