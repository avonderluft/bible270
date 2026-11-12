# frozen_string_literal: true

require 'test_helper'
require 'bible270/reader_consistency'
require 'bible270/reader_progress_report'

if RAILS_LOADED
  class ParticipationsTest < Minitest::Test
    def setup
      needs_rails!
      clear_engine_tables!
      @previous = %i[start_date allow_reader_start_date mention_notifications time_zone].to_h do |key|
        [key, Bible270.config.public_send(key)]
      end
      Bible270.config.start_date = Date.new(2026, 1, 1)
      Bible270.config.allow_reader_start_date = true
      Bible270.config.mention_notifications = false
      Bible270.config.time_zone = 'UTC'
      @reader = Bible270::Reader.create!(display_name: 'Reader', provider: 'email', uid: 'reader@example.org',
                                         email: 'reader@example.org', created_at: Time.utc(2025, 12, 1))
    end

    def teardown
      @previous&.each { |key, value| Bible270.config.public_send("#{key}=", value) }
    end

    def test_every_new_reader_is_enrolled_before_the_registration_notice
      observed = nil
      callback = ->(reader_id:, recipients:) do
        assert_equal ['admin@example.org'], recipients
        observed = Bible270::Reader.find(reader_id).participation
        Object.new.tap { |mail| mail.define_singleton_method(:deliver_now) { true } }
      end
      previous_recipients = Bible270.config.registration_notice_emails
      previous_later = Bible270.config.registration_notice_deliver_later
      Bible270.config.registration_notice_emails = ['admin@example.org']
      Bible270.config.registration_notice_deliver_later = false
      Bible270::NoticeMailer.stub(:new_reader, callback) do
        reader = Bible270::Reader.create!(display_name: 'New reader')
        assert_equal reader.participation, observed
        assert_equal Bible270::PlanRun.current, observed.plan_run
        assert observed.active?
        assert_equal reader.created_at, observed.joined_at
      end
    ensure
      Bible270.config.registration_notice_emails = previous_recipients
      Bible270.config.registration_notice_deliver_later = previous_later
    end

    def test_schedule_guard_transaction_is_retained_through_both_schedule_updates
      connection = Bible270::Reader.connection
      statements = []
      subscriber = ->(_name, _start, _finish, _id, payload) do
        sql = payload[:sql]
        next unless sql.match?(%r{SELECT.*FROM "bible270_plan_runs"|UPDATE "bible270_(?:readers|participations)"}i)

        assert connection.transaction_open?
        statements << [sql, connection.current_transaction.object_id]
      end
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        @reader.set_start_date!('2026-03-01')
      end
      assert_match(%r{SELECT.*FROM "bible270_plan_runs"}i, statements.first.first)
      assert_match(%r{UPDATE "bible270_readers"}, statements[-2].first)
      assert_match(%r{UPDATE "bible270_participations"}, statements.last.first)
      assert_equal 1, statements.map(&:last).uniq.size
      assert_equal Date.new(2026, 3, 1), @reader.participation.reload.started_on
      refute connection.transaction_open?
    end

    def test_new_reader_reselects_current_run_when_the_selected_run_was_archived_before_locking
      stale_run = Bible270::PlanRun.current
      fresh_run = restart_run
      selections = 0
      select_run = -> do
        selections += 1
        selections == 1 ? stale_run : fresh_run
      end

      Bible270::PlanRun.stub(:current, select_run) do
        reader = Bible270::Reader.from_email('new-reader@example.org')
        assert reader.persisted?
        assert_equal fresh_run, reader.participation.plan_run
        assert reader.participation.active?
        assert_equal 1, reader.participations.count
        assert_equal 2, selections
        assert_equal @reader, Bible270::Reader.from_email(@reader.email)
        assert_equal 2, selections, 'Existing reader sign-in must not attempt enrollment'
      end
      assert @reader.reload_progress.alumni?
      assert_equal 1, stale_run.participations.count
    end

    def test_new_reader_enrollment_retries_are_bounded_and_roll_back_creation
      stale_run = Bible270::PlanRun.current
      restart_run
      selections = 0
      select_run = -> {
        selections += 1
        stale_run
      }
      Bible270::PlanRun.stub(:current, select_run) do
        assert_raises(Bible270::PlanRun::StaleRun) do
          Bible270::Reader.from_email('never-enrolled@example.org')
        end
      end
      assert_equal 3, selections
      refute Bible270::Reader.exists?(email: 'never-enrolled@example.org')
      assert_equal 1, Bible270::Participation.count
      assert @reader.reload_progress.alumni?
    end

    def test_legacy_bulk_insert_keeps_the_run_lock_and_transaction_through_insertion
      membership = @reader.participation
      connection = Bible270::Checkoff.connection
      inserted_under_lock = false
      capture_run_locks do |locks|
        subscriber = ->(_name, _start, _finish, _id, payload) do
          next unless payload[:sql].match?(%r{INSERT.*INTO ["`]?bible270_checkoffs}i)

          assert connection.transaction_open?
          assert_equal 1, locks.size
          assert locks.first.lock_value
          assert_equal [membership.plan_run_id], locks.first.map(&:id)
          inserted_under_lock = true
        end
        ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
          result = Bible270::Checkoff.insert_all([legacy_checkoff_row], returning: %w[id participation_id])
          assert_equal membership.id, result.to_a.first.fetch('participation_id')
        end
      end
      assert inserted_under_lock
      refute connection.transaction_open?
      assert_equal 1, @reader.checkoffs.count
    end

    def test_legacy_bulk_insert_reloads_membership_if_archive_wins_before_run_lock
      interleaved = false
      subscriber = ->(_name, _start, _finish, _id, payload) do
        next if interleaved || !payload[:sql].match?(%r{SELECT.*FROM "bible270_participations".*NOT EXISTS}im)

        interleaved = true
        @reader.archive!
      end
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        assert_raises(Bible270::Participation::ArchivedProgress) do
          Bible270::Checkoff.insert_all([legacy_checkoff_row])
        end
      end
      assert interleaved
      assert_empty Bible270::Checkoff.where(reader_id: @reader.id)
    end

    def test_legacy_bulk_insert_revalidates_if_restart_wins_before_run_lock
      interleaved = false
      subscriber = ->(_name, _start, _finish, _id, payload) do
        next if interleaved || !payload[:sql].match?(%r{SELECT.*FROM "bible270_participations".*NOT EXISTS}im)

        interleaved = true
        restart_run
      end
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        assert_raises(Bible270::Participation::ArchivedProgress) do
          Bible270::Checkoff.insert_all([legacy_checkoff_row])
        end
      end
      assert interleaved
      assert_empty Bible270::Checkoff.where(reader_id: @reader.id)
    end

    def test_legacy_bulk_insert_locks_all_relevant_runs_in_id_order_before_revalidation
      old_run = Bible270::PlanRun.current
      fresh_run = restart_run
      other = Bible270::Reader.create!(display_name: 'Current reader')
      capture_run_locks do |locks|
        assert_raises(Bible270::Participation::ArchivedProgress) do
          Bible270::Checkoff.insert_all([legacy_checkoff_row(other), legacy_checkoff_row])
        end
        assert_equal 1, locks.size
        assert locks.first.lock_value
        assert_match(%r{ORDER BY "bible270_plan_runs"\."id" ASC}, locks.first.to_sql)
        assert_equal [old_run.id, fresh_run.id], locks.first.map(&:id)
      end
      assert_empty Bible270::Checkoff.all
    end

    def test_bulk_insert_with_explicit_participation_remains_a_trusted_bypass
      membership = @reader.archive!
      capture_run_locks do |locks|
        Bible270::Checkoff.insert_all([legacy_checkoff_row.merge(participation_id: membership.id)])
        assert_empty locks
      end
      assert_equal 1, membership.checkoffs.count
    end

    def test_returning_in_a_new_run_gets_fresh_progress_and_a_reset_personal_date
      @reader.set_start_date!('2026-02-01')
      @reader.mark_day_complete!(1)
      old = @reader.participation
      old_ids = @reader.checkoffs.pluck(:id)
      fresh = restart_run
      membership = @reader.reload_progress.activate!
      assert_equal fresh, membership.plan_run
      assert_nil @reader.started_on
      assert_nil membership.started_on
      assert_equal Date.new(2027, 1, 1), @reader.effective_start_date
      assert_equal 0, @reader.days_completed
      assert_empty @reader.checkoffs
      @reader.mark_day_complete!(1)
      assert_equal 1, @reader.days_completed
      assert_equal old_ids, old.checkoffs.pluck(:id)
      assert_equal Date.new(2026, 2, 1), old.reload.started_on
      assert_equal 2, @reader.participations.count
      assert_equal Bible270::Plan.total_parts(1) * 2, @reader.all_checkoffs.count
      assert_equal 1, Bible270::Reader.completed_days_by_id.fetch(@reader.id)
    end

    def test_same_run_reactivation_retains_progress_and_personal_schedule
      @reader.set_start_date!('2026-02-01')
      @reader.mark_day_complete!(1)
      membership = @reader.participation
      @reader.archive!
      @reader.activate!
      assert_equal membership, @reader.participation
      assert_equal 1, @reader.days_completed
      assert_equal Date.new(2026, 2, 1), @reader.started_on
      assert_equal Date.new(2026, 2, 1), @reader.effective_start_date
      assert_nil @reader.participation.archived_on
      assert_nil @reader.participation.frozen_start_date
      assert_equal 1, @reader.participations.count
    end

    def test_shared_schedule_calendar_and_consistency_are_frozen_at_archive
      @reader.mark_day_complete!(1)
      @reader.checkoffs.update_all(created_at: Time.utc(2026, 1, 1, 12))
      cutoff = Date.new(2026, 1, 8)
      before = Bible270::ReaderConsistency.new(readers: [@reader], today: cutoff).for(@reader)
      Bible270.stub(:today, cutoff) { @reader.archive! }
      status = @reader.progress_status
      Bible270::Setting.set_run_start_date!('2030-01-01')
      Bible270.config.start_date = Date.new(2031, 1, 1)
      Bible270.config.allow_reader_start_date = false
      Bible270.stub(:today, Date.new(2032, 1, 1)) do
        assert_equal Date.new(2026, 1, 1), @reader.effective_start_date
        assert_equal cutoff, @reader.progress_today
        assert_equal 8, @reader.calendar_day
        assert_equal status, @reader.progress_status
        after = Bible270::ReaderConsistency.new(readers: [@reader]).for(@reader)
        assert_equal before, after
      end
    end

    def test_an_undated_archive_stays_undated
      Bible270.config.start_date = nil
      @reader.archive!
      Bible270::Setting.set_run_start_date!('2027-01-01')
      assert_nil @reader.effective_start_date
      assert_nil @reader.calendar_day
      assert_equal 'undated', @reader.progress_status
    end

    def test_personal_snapshot_ignores_later_configuration_changes
      @reader.set_start_date!('2026-02-01')
      @reader.archive!
      Bible270.config.allow_reader_start_date = false
      Bible270::Setting.set_run_start_date!('2027-01-01')
      assert_equal Date.new(2026, 2, 1), @reader.effective_start_date
      assert_equal Date.new(2026, 2, 1), @reader.participation.effective_start_date
      assert_raises(Bible270::Participation::ArchivedProgress) { @reader.set_start_date!('2028-01-01') }
    end

    def test_sign_in_and_reflections_do_not_reactivate_alumni
      @reader.archive!
      assert_equal @reader, Bible270::Reader.from_email('reader@example.org')
      @reader.comments.create!(day: 1, body: 'An alumni reflection')
      @reader.ensure_started!
      assert @reader.reload_progress.alumni?
      assert_includes Bible270::Reader.alumni, @reader
      refute_includes Bible270::Reader.active, @reader
      assert_includes Bible270::Reader.all, @reader
    end

    def test_chosen_membership_bulk_counts_recent_activity_and_completers_do_not_mix_runs
      @reader.mark_day_complete!(1)
      @reader.mark_day_complete!(2)
      old = @reader.participation
      restart_run
      assert_equal old, @reader.reload_progress.participation
      assert_equal 2, Bible270::Reader.completed_days_by_id.fetch(@reader.id)
      assert_equal 2, Bible270::Checkoff.recent_activity_by_reader([@reader.id]).fetch(@reader.id).day
      assert_empty Bible270::Reader.completers_for(1)
      @reader.activate!
      assert_equal 0, Bible270::Reader.completed_days_by_id[@reader.id]
      assert_empty Bible270::Checkoff.recent_activity_by_reader([@reader.id])
      @reader.mark_day_complete!(1)
      @reader.checkoffs.create!(day: 2, track: 'nt', part: 0)
      assert_equal 1, Bible270::Reader.completed_days_by_id.fetch(@reader.id)
      activity = Bible270::Checkoff.recent_activity_by_reader([@reader.id]).fetch(@reader.id)
      assert_equal 2, activity.day
      refute activity.day_completed?
      assert_equal [@reader], Bible270::Reader.completers_for(1)
      @reader.archive!
      assert_empty Bible270::Reader.completers_for(1)
    end

    def test_consistency_starts_at_the_new_membership_not_original_identity_creation
      restart_run
      Bible270.stub(:today, Date.new(2027, 1, 5)) do
        travel_to(Time.utc(2027, 1, 5, 12)) { @reader.reload_progress.activate! }
      end
      result = Bible270::ReaderConsistency.new(readers: [@reader], today: Date.new(2027, 1, 8)).for(@reader)
      assert_equal 3, result.days_evaluated
      assert_equal Rational(40), result.score
    end

    def test_historical_completions_do_not_contribute_to_new_run_consistency
      (1..7).each { |day| @reader.mark_day_complete!(day) }
      @reader.checkoffs.update_all(created_at: Time.utc(2026, 1, 1, 12))
      restart_run
      travel_to(Time.utc(2027, 1, 1, 12)) { @reader.reload_progress.activate! }
      result = Bible270::ReaderConsistency.new(readers: [@reader], today: Date.new(2027, 1, 8)).for(@reader)
      assert_equal 7, result.days_evaluated
      assert_equal Rational(60), result.score
      assert_equal Rational(0), result.on_track_percentage
    end

    def test_multiple_alumni_keep_distinct_frozen_shared_schedules_in_bulk_consistency
      Bible270.stub(:today, Date.new(2026, 1, 8)) { @reader.archive! }
      Bible270::Setting.set_run_start_date!('2026-01-06')
      other = Bible270::Reader.create!(display_name: 'Later reader', created_at: Time.utc(2025, 12, 1))
      Bible270.stub(:today, Date.new(2026, 1, 8)) { other.archive! }
      Bible270::Setting.set_run_start_date!('2028-01-01')
      calculator = Bible270::ReaderConsistency.new(readers: [@reader, other], today: Date.new(2030, 1, 1))
      assert_equal 7, calculator.for(@reader).days_evaluated
      assert_equal 2, calculator.for(other).days_evaluated
    end

    def test_direct_creates_assign_membership_and_reject_cross_reader_spoofing
      direct = Bible270::Checkoff.create!(reader: @reader, day: 1, track: 'nt', part: 0)
      assert_equal @reader.participation, direct.participation
      associated = @reader.checkoffs.create!(day: 1, track: 'ot', part: 0)
      assert_equal @reader.participation, associated.participation
      other = Bible270::Reader.create!(display_name: 'Other reader')
      spoof = Bible270::Checkoff.new(reader: @reader, participation: other.participation, day: 2, track: 'nt', part: 0)
      refute spoof.valid?
      assert_includes spoof.errors[:participation], 'must belong to the same reader'
      assert_raises(ActiveRecord::RecordInvalid) { direct.update!(participation: other.participation, reader: other) }
    end

    def test_archived_progress_rejects_ordinary_model_writes_but_can_be_read
      @reader.mark_day_complete!(1)
      checkoff = @reader.checkoffs.first
      @reader.archive!
      assert_equal 1, @reader.days_completed
      assert_equal Bible270::Plan.total_parts(1), @reader.checkoffs.count
      [-> { @reader.mark_day_complete!(2) }, -> { @reader.clear_day!(1) },
       -> { @reader.mark_through!(0) }, -> { @reader.restart_on!(day: 1) },
       -> { checkoff.destroy! }].each do |write|
        assert_raises(Bible270::Participation::ArchivedProgress, &write)
      end
      assert_raises(ActiveRecord::RecordInvalid) { checkoff.update!(part: 0) }
      assert_raises(ActiveRecord::RecordInvalid) { @reader.checkoffs.create!(day: 2, track: 'nt', part: 0) }
      assert_raises(ActiveRecord::RecordInvalid) do
        Bible270::Checkoff.create!(reader: @reader, day: 2, track: 'nt', part: 0)
      end
      assert_equal 1, @reader.reload_progress.days_completed
    end

    def test_a_reader_cached_before_restart_cannot_write_to_archived_progress
      @reader.mark_day_complete!(1)
      restart_run
      assert_raises(Bible270::Participation::ArchivedProgress) { @reader.mark_day_complete!(2) }
      assert_raises(ActiveRecord::RecordInvalid) { @reader.checkoffs.create!(day: 2, track: 'nt', part: 0) }
    end

    def test_destroying_reader_cascades_all_run_progress_and_memberships
      @reader.mark_day_complete!(1)
      restart_run
      @reader.reload_progress.activate!
      @reader.mark_day_complete!(2)
      @reader.archive!
      @reader.destroy!
      assert_empty Bible270::Checkoff.where(reader_id: @reader.id)
      assert_empty Bible270::Participation.where(reader_id: @reader.id)
      assert_equal 2, Bible270::PlanRun.count
    end

    def test_raw_identity_deletion_also_cascades_all_memberships_and_progress
      @reader.mark_day_complete!(1)
      restart_run
      @reader.reload_progress.activate!
      @reader.mark_day_complete!(2)
      Bible270::Reader.where(id: @reader.id).delete_all
      assert_empty Bible270::Checkoff.where(reader_id: @reader.id)
      assert_empty Bible270::Participation.where(reader_id: @reader.id)
    end

    def test_alumni_are_excluded_from_group_notifications_and_default_report_not_personal_preferences
      @reader.update!(daily_reminders: true, notify_on_all_comments: true, notify_on_mention: true)
      @reader.archive!
      assert_empty Bible270::Reader.daily_reminder_recipients(on: Bible270.today)
      assert_empty Bible270::Reader.all_comment_notification_recipients
      assert @reader.wants_comment_notifications?
      assert @reader.wants_all_comment_notifications?
      assert Bible270::ReaderProgressReport.new.empty?
      refute Bible270::ReaderProgressReport.new(readers: [@reader]).empty?
      @reader.activate!
      assert_includes Bible270::Reader.daily_reminder_recipients(on: Bible270.today), @reader
      assert_includes Bible270::Reader.all_comment_notification_recipients, @reader
      refute Bible270::ReaderProgressReport.new.empty?
    end

    def test_reload_progress_clears_counts_and_selected_membership_cache
      assert_equal 0, @reader.days_completed
      @reader.checkoffs.create!(day: 1, track: 'nt', part: 0)
      assert_equal 0, @reader.checked_count(1)
      assert_equal 1, @reader.reload_progress.checked_count(1)
      restart_run
      @reader.reload_progress.activate!
      assert_equal 0, @reader.checked_count(1)
    end

    def test_with_avatar_preloads_membership_and_run_without_per_reader_queries
      5.times { |index| Bible270::Reader.create!(display_name: "Reader #{index}") }
      readers = Bible270::Reader.with_avatar.to_a
      queries = []
      subscriber = ->(_name, _start, _finish, _id, payload) do
        queries << payload[:sql] if payload[:sql].match?(%r{\ASELECT}i)
      end
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        readers.each do |reader|
          refute reader.alumni?

          assert reader.participation.plan_run.current?
        end
      end
      assert_empty queries
    end

  private

    include ActiveSupport::Testing::TimeHelpers

    def legacy_checkoff_row(reader = @reader)
      { reader_id: reader.id, day: 1, track: 'nt', part: 0, created_at: Time.current, updated_at: Time.current }
    end

    # SQLite does not expose FOR UPDATE in SQL. Observe the real relation's lock
    # flag without replacing its database reads, so the same assertions test the
    # transaction boundary and deterministic lock order on the dummy database.
    def capture_run_locks
      locks = []
      original_where = Bible270::PlanRun.method(:where)
      tracked_where = ->(*arguments) do
        relation = original_where.call(*arguments)
        original_order = relation.method(:order)
        relation.define_singleton_method(:order) do |*columns|
          ordered = original_order.call(*columns)
          original_lock = ordered.method(:lock)
          ordered.define_singleton_method(:lock) do |*options|
            original_lock.call(*options).tap { |locked| locks << locked }
          end
          ordered
        end
        relation
      end
      Bible270::PlanRun.stub(:where, tracked_where) { yield locks }
    end

    def restart_run
      Bible270::PlanRun.restart!(start_date: '2027-01-01', expected_run_id: Bible270::PlanRun.current.id)
    end
  end
end
