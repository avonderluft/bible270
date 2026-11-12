# frozen_string_literal: true

require 'test_helper'
require 'bible270/reader_consistency'
require 'bible270/reader_progress_report'

if RAILS_LOADED
  class PlanRunsTest < Minitest::Test
    def setup
      needs_rails!
      clear_engine_tables!
      @previous = %i[start_date allow_reader_start_date enrollment_open mention_notifications admin_emails admin_resolver].to_h do |key|
        [key, Bible270.config.public_send(key)]
      end
      Bible270.config.start_date = Date.new(2026, 1, 1)
      Bible270.config.allow_reader_start_date = true
      Bible270.config.mention_notifications = false
      Bible270.config.admin_emails = []
      Bible270.config.admin_resolver = nil
    end

    def teardown
      @previous&.each { |key, value| Bible270.config.public_send("#{key}=", value) }
    end

    def test_current_initializes_an_empty_database_once
      assert_equal 0, Bible270::PlanRun.count
      run = Bible270::PlanRun.current
      assert_equal run, Bible270::PlanRun.current
      assert run.current?
      assert_equal 1, Bible270::PlanRun.count
      assert_raises(ActiveRecord::RecordNotUnique) { Bible270::PlanRun.create!(current: true) }
    end

    def test_restart_archives_memberships_and_opens_a_new_run_without_destroying_content
      reader = Bible270::Reader.create!(display_name: 'Returning reader', started_on: Date.new(2026, 2, 1))
      reader.mark_day_complete!(1)
      comment = reader.comments.create!(day: 1, body: 'Keep this reflection')
      like = comment.likes.create!(reader: reader)
      old = reader.participation
      checkoff_ids = reader.checkoffs.pluck(:id)
      Bible270.config.enrollment_open = false
      Bible270::Setting.close_enrollment!
      date = Date.new(2027, 1, 1)

      fresh = Bible270::PlanRun.restart!(start_date: date.iso8601, expected_run_id: old.plan_run_id)

      assert_equal fresh, Bible270::PlanRun.current
      assert fresh.current?
      assert_equal date, fresh.start_date
      assert_equal date, Bible270::Setting.run_start_date
      refute Bible270::Setting.enrollment_closed?
      assert_nil old.plan_run.reload.current
      assert old.plan_run.archived_at
      assert old.reload.alumni?
      assert_equal Date.new(2026, 2, 1), old.frozen_start_date
      assert_equal Bible270.today, old.archived_on
      assert_equal checkoff_ids, old.checkoffs.pluck(:id)
      assert_equal reader.id, comment.reload.reader_id
      assert_equal reader.id, like.reload.reader_id
      assert_equal 0, fresh.participations.count
      assert_equal old, reader.reload_progress.participation
      assert reader.alumni?
      assert_equal 1, reader.days_completed
    ensure
      like&.destroy!
    end

    def test_each_restart_gives_all_current_admins_fresh_memberships_without_carrying_over_progress
      personal_date = Date.new(2026, 2, 1)
      admins = [
        Bible270::Reader.create!(display_name: 'Active admin', admin: true, started_on: personal_date),
        Bible270::Reader.create!(display_name: 'Alumni admin', admin: true, started_on: personal_date),
        Bible270::Reader.create!(display_name: 'Active site-admin', email: 'active-site@example.org', started_on: personal_date),
        Bible270::Reader.create!(display_name: 'Alumni site-admin', email: 'alumni-site@example.org', started_on: personal_date)
      ]
      ordinary = Bible270::Reader.create!(display_name: 'Ordinary reader', started_on: personal_date)
      Bible270.config.admin_emails = admins.last(2).map(&:email)
      (admins + [ordinary]).each { |reader| reader.mark_day_complete!(1) }
      [admins[1], admins[3]].each(&:archive!)
      already_alumni = [admins[1], admins[3]].to_h { |reader| [reader.participation.id, reader.participation.attributes] }
      original_memberships = (admins + [ordinary]).map(&:participation)
      old_checkoffs = Bible270::Checkoff.order(:id).map(&:attributes)
      original_roles = Bible270::Reader.order(:id).pluck(:id, :admin)

      2.times do |index|
        current = Bible270::PlanRun.current
        date = Date.new(2027 + index, 1, 1)
        fresh = Bible270::PlanRun.restart!(start_date: date, expected_run_id: current.id)

        assert_equal admins.map(&:id).sort, Bible270::Reader.active.order(:id).pluck(:id)
        assert_equal admins.size, fresh.participations.count
        admins.each do |reader|
          reader.reload
          refute reader.alumni?
          assert_equal fresh.id, reader.participation.plan_run_id
          assert_nil reader.started_on
          assert_nil reader.participation.started_on
          assert_equal date, reader.effective_start_date
          assert_equal 0, reader.days_completed
          assert_empty reader.checkoffs
        end
        assert ordinary.reload.alumni?
        assert_equal original_roles, Bible270::Reader.order(:id).pluck(:id, :admin)
        assert_equal old_checkoffs, Bible270::Checkoff.order(:id).map(&:attributes)
        original_memberships.each do |membership|
          assert membership.reload.alumni?
          assert_equal personal_date, membership.started_on
          assert_equal personal_date, membership.frozen_start_date
        end
        already_alumni.each do |id, attributes|
          assert_equal attributes, Bible270::Participation.find(id).attributes
        end
        # Give this group progress too, to verify the next restart stays empty.
        admins.each { |reader| reader.mark_day_complete!(2) }
        old_checkoffs = Bible270::Checkoff.order(:id).map(&:attributes)
      end
    end

    def test_invalid_and_stale_restarts_leave_everything_unchanged
      reader = Bible270::Reader.create!(display_name: 'Reader')
      run = Bible270::PlanRun.current
      [nil, '', 'bad date'].each do |date|
        assert_raises(Bible270::PlanRun::InvalidStartDate) do
          Bible270::PlanRun.restart!(start_date: date, expected_run_id: run.id)
        end
      end
      [nil, '', run.id + 1].each do |expected|
        assert_raises(Bible270::PlanRun::StaleRun) do
          Bible270::PlanRun.restart!(start_date: '2027-01-01', expected_run_id: expected)
        end
      end
      assert_equal 1, Bible270::PlanRun.count
      refute reader.reload_progress.alumni?
      fresh = Bible270::PlanRun.restart!(start_date: '2027-01-01', expected_run_id: run.id)
      assert_raises(Bible270::PlanRun::StaleRun) do
        Bible270::PlanRun.restart!(start_date: '2027-02-01', expected_run_id: run.id)
      end
      assert_equal 2, Bible270::PlanRun.count
      assert_equal fresh, Bible270::PlanRun.current
    end

    def test_failure_rolls_back_run_memberships_and_settings_together
      reader = Bible270::Reader.create!(display_name: 'Reader')
      run = Bible270::PlanRun.current
      Bible270::Setting.close_enrollment!
      Bible270::Setting.stub(:open_enrollment!, -> { raise 'simulated failure' }) do
        assert_raises(RuntimeError) do
          Bible270::PlanRun.restart!(start_date: '2027-01-01', expected_run_id: run.id)
        end
      end
      assert_equal run, Bible270::PlanRun.current
      assert_nil run.reload.archived_at
      refute reader.reload_progress.alumni?
      assert_equal 1, Bible270::PlanRun.count
      refute Bible270::Setting.run_start_date_overridden?
      assert Bible270::Setting.enrollment_closed?
    end

    def test_restart_does_not_overwrite_existing_alumni_snapshots
      reader = Bible270::Reader.create!(display_name: 'Early alumni')
      Bible270.stub(:today, Date.new(2026, 2, 1)) { reader.archive! }
      old = reader.participation
      Bible270::Setting.set_run_start_date!('2026-03-01')
      Bible270::PlanRun.restart!(start_date: '2027-01-01', expected_run_id: old.plan_run_id)
      assert_equal Date.new(2026, 2, 1), old.reload.archived_on
      assert_equal Date.new(2026, 1, 1), old.frozen_start_date
    end

    def test_explicit_runtime_open_overrides_closed_configuration_and_can_be_closed_again
      Bible270.config.enrollment_open = false
      assert Bible270::Setting.enrollment_closed?
      Bible270::Setting.open_enrollment!
      refute Bible270::Setting.enrollment_closed?
      Bible270::Setting.close_enrollment!
      assert Bible270::Setting.enrollment_closed?
    end
  end

  class PlanRunsMigrationTest < Minitest::Test
    def test_existing_rows_are_backfilled_without_callbacks_or_rewriting_progress
      needs_rails!
      clear_engine_tables!
      require_relative '../db/migrate/20260101000024_create_bible270_plan_runs'
      connection = ActiveRecord::Base.connection
      migration = CreateBible270PlanRuns.new
      # Transactional DDL restores the normal schema even if an assertion fails.
      ActiveRecord::Base.transaction(requires_new: true) do
        # Reconstruct the pre-00024 schema, without rolling back earlier migrations.
        connection.remove_index :bible270_checkoffs, name: 'idx_b270_checkoffs_part_unique'
        connection.remove_reference :bible270_checkoffs, :participation,
                                    foreign_key: { to_table: :bible270_participations }
        connection.drop_table :bible270_participations
        connection.drop_table :bible270_plan_runs
        connection.add_index :bible270_checkoffs, %i[reader_id day track part], unique: true,
                                                                                name: 'idx_b270_checkoffs_part_unique'
        connection.execute <<~SQL
          INSERT INTO bible270_readers (id, display_name, started_on, created_at, updated_at)
          VALUES (8001, 'Legacy Reader', '2025-10-01', '2025-09-15 12:00:00', '2025-09-20 12:00:00')
        SQL
        connection.execute <<~SQL
          INSERT INTO bible270_readers (id, display_name, created_at, updated_at)
          VALUES (8002, 'No progress', '2025-09-16 12:00:00', '2025-09-20 12:00:00')
        SQL
        connection.execute <<~SQL
          INSERT INTO bible270_checkoffs (id, reader_id, day, track, part, created_at, updated_at)
          VALUES (9001, 8001, 1, 'ot', 2, '2025-10-03 12:00:00', '2025-10-04 12:00:00')
        SQL
        before = connection.select_one('SELECT * FROM bible270_checkoffs WHERE id = 9001')
        Bible270::PlanRun.stub(:current, -> { flunk 'Migration must not call application models' }) do
          migration.up
        end
        Bible270::Checkoff.reset_column_information
        Bible270::Participation.reset_column_information
        Bible270::PlanRun.reset_column_information
        after = connection.select_one('SELECT * FROM bible270_checkoffs WHERE id = 9001')
        assert_equal before, after.except('participation_id')
        membership = Bible270::Participation.find(after.fetch('participation_id'))
        assert_equal 8001, membership.reader_id
        assert_equal Date.new(2025, 10, 1), membership.started_on
        assert_equal Time.utc(2025, 9, 15, 12), membership.joined_at
        assert membership.active?
        assert membership.plan_run.current?
        assert_equal 2, Bible270::Participation.count
        refute connection.columns(:bible270_checkoffs).find { |column| column.name == 'participation_id' }.null
        assert_equal %w[participation_id day track part],
                     connection.indexes(:bible270_checkoffs).find { |index| index.name == 'idx_b270_checkoffs_part_unique' }.columns
        raise ActiveRecord::Rollback
      end
    ensure
      if RAILS_LOADED
        Bible270::Checkoff.reset_column_information
        Bible270::Participation.reset_column_information
        Bible270::PlanRun.reset_column_information
      end
    end
  end
end
