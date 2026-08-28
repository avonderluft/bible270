# frozen_string_literal: true

require 'test_helper'

# The model against a real database: completion arithmetic, progress counts and
# the administrative setters. Written to work whether or not per-chapter
# check-offs are in place — boxes_on(day) asks the code rather than assuming.
class ReaderTest < Minitest::Test
  def setup
    needs_rails!
    clear_engine_tables!
    @reader = Bible270::Reader.create!(provider: 'email', uid: 'a@example.org',
                                       email: 'a@example.org', display_name: 'A Reader')
  end

  def test_a_reader_starts_with_nothing_done
    assert_equal 0, @reader.days_completed
    refute @reader.day_complete?(1)
    assert_equal :none, @reader.day_status(1)
    refute @reader.daily_reminders
    assert_equal '08:00', @reader.daily_reminder_time
    assert_nil @reader.last_daily_reminder_sent_on
  end

  def test_optional_reader_columns_are_available_in_the_migrated_schema
    assert Bible270::Reader.daily_reminder_columns?
    assert Bible270::Reader.reflections_seen_column?
    assert Bible270::Reader.comment_notification_columns?
  end

  def test_comment_notification_columns_refresh_a_stale_schema_cache
    calls = 0
    column_names = -> do
      calls += 1
      calls == 1 ? ['notify_on_mention'] : Bible270::Reader::COMMENT_NOTIFICATION_COLUMNS
    end
    reset = false

    Bible270::Reader.stub(:column_names, column_names) do
      Bible270::Reader.stub(:reset_column_information, -> { reset = true }) do
        assert Bible270::Reader.comment_notification_columns?
      end
    end
    assert reset
  end

  def test_mention_suggestions_rank_handles_before_surnames_and_exclude_the_writer
    andrew = create_named_reader('Andrew', 'Smith')
    create_named_reader('Beth', 'Andrew')

    suggestions = Bible270::Reader.mention_suggestions('and', except: @reader)
    assert_equal ['@andrew.smith', '@beth.andrew'], suggestions.pluck(:handle)

    suggestions = Bible270::Reader.mention_suggestions('and', except: andrew)
    assert_equal ['@beth.andrew'], suggestions.pluck(:handle)
  end

  def test_mention_suggestions_omit_ambiguous_full_handles_and_do_not_fuzzy_match
    2.times { |index| create_named_reader('Sam', 'Jones', suffix: index) }
    create_named_reader('Amanda', 'Stone')

    assert_empty Bible270::Reader.mention_suggestions('sam')
    assert_empty Bible270::Reader.mention_suggestions('mand')
  end

  def test_mention_suggestions_are_alphabetical_and_limited_to_five
    6.times { |index| create_named_reader("Ann#{index}", 'Reader') }

    suggestions = Bible270::Reader.mention_suggestions('ann')

    assert_equal 5, suggestions.size
    assert_equal %w[@ann0.reader @ann1.reader @ann2.reader @ann3.reader @ann4.reader],
                 suggestions.pluck(:handle)
  end

  def test_marking_reflections_seen_is_safe_when_the_migration_is_pending
    Bible270::Reader.stub(:reflections_seen_column?, false) do
      refute @reader.mark_reflections_seen!(Time.current)
    end
  end

  def test_missing_daily_reminder_columns_do_not_block_unrelated_updates
    @reader.update_column(:daily_reminder_time, 'invalid')

    Bible270::Reader.stub(:daily_reminder_columns?, false) do
      assert @reader.update!(display_name: 'Renamed Reader')
      refute @reader.daily_reminder_due_at?(Time.utc(2026, 9, 6, 8, 0))
    end
  end

  def test_daily_reminder_scope_only_returns_opted_in_reachable_readers_not_sent_that_day
    on = Date.new(2026, 9, 6)
    due = Bible270::Reader.create!(
      provider: 'email', uid: 'due@example.org', email: 'due@example.org',
      display_name: 'Due Reader', daily_reminders: true
    )
    Bible270::Reader.create!(
      provider: 'email', uid: 'out@example.org', email: 'out@example.org',
      display_name: 'Opted Out', daily_reminders: false
    )
    Bible270::Reader.create!(
      provider: 'owner', uid: 'no-email', display_name: 'No Email', daily_reminders: true
    )
    Bible270::Reader.create!(
      provider: 'email', uid: 'sent@example.org', email: 'sent@example.org',
      display_name: 'Already Sent', daily_reminders: true, last_daily_reminder_sent_on: on
    )

    assert_equal [due.id], Bible270::Reader.daily_reminder_recipients(on: on).pluck(:id)
  end

  def test_daily_reminder_time_requires_strict_24_hour_hours_and_minutes
    %w[00:00 08:00 12:34 23:59].each do |value|
      @reader.daily_reminder_time = value
      assert @reader.valid?, "#{value.inspect} should be valid"
    end

    ['8:00', '08:0', '24:00', '12:60', '12:34:00', '', nil].each do |value|
      @reader.daily_reminder_time = value
      refute @reader.valid?, "#{value.inspect} should be invalid"
      assert_includes @reader.errors[:daily_reminder_time], 'must use 24-hour HH:MM format'
    end
  end

  def test_daily_reminder_is_due_at_or_after_the_chosen_local_time
    @reader.update!(daily_reminders: true, daily_reminder_time: '08:00')

    refute @reader.daily_reminder_due_at?(Time.utc(2026, 9, 6, 7, 59))
    assert @reader.daily_reminder_due_at?(Time.utc(2026, 9, 6, 8, 0))
    assert @reader.daily_reminder_due_at?(Time.utc(2026, 9, 6, 17, 30))
    refute @reader.daily_reminder_due_at?(nil)
  end

  def test_daily_reminder_is_not_due_when_the_reader_is_opted_out
    @reader.update!(daily_reminders: false, daily_reminder_time: '00:00')

    refute @reader.daily_reminder_due_at?(Time.utc(2026, 9, 6, 23, 59))
  end

  def test_marking_a_day_complete_ticks_every_box
    @reader.mark_day_complete!(1)

    assert_equal boxes_on(1), @reader.checkoffs.where(day: 1).count
    assert @reader.day_complete?(1)
    assert_equal :complete, @reader.day_status(1)
    assert_equal 1, @reader.days_completed
  end

  def test_a_partly_read_day_is_not_complete
    @reader.checkoffs.create!(day: 1, track: 'nt')
    @reader.reload_progress

    refute @reader.day_complete?(1)
    assert_equal :partial, @reader.day_status(1)
    assert_equal 0, @reader.days_completed
  end

  def test_clearing_a_day_removes_everything_on_it
    @reader.mark_day_complete!(1)
    @reader.clear_day!(1)

    assert_equal 0, @reader.checkoffs.where(day: 1).count
    refute @reader.day_complete?(1)
  end

  def test_marking_through_a_day_sets_progress_exactly
    @reader.mark_through!(3)
    assert_equal 3, @reader.days_completed

    # Also clears anything after, so it sets progress rather than adding to it.
    @reader.mark_through!(1)
    assert_equal 1, @reader.days_completed
    assert_equal 0, @reader.checkoffs.where(day: 2..).count
  end

  def test_marking_through_zero_clears_everything
    @reader.mark_through!(2)
    @reader.mark_through!(0)

    assert_equal 0, @reader.days_completed
    assert_equal 0, @reader.checkoffs.count
  end

  def test_days_outside_the_plan_are_refused
    refute @reader.mark_day_complete!(0)
    refute @reader.mark_day_complete!(Bible270::Plan::DAYS + 1)
    refute @reader.mark_through!(Bible270::Plan::DAYS + 1)
  end

  def test_names_are_set_together_or_not_at_all
    refute @reader.update_names('Andrew', '')
    refute @reader.update_names('', 'vonderLuft')
    assert @reader.update_names('Andrew', 'vonderLuft')

    @reader.reload
    assert_equal 'Andrew vonderLuft', @reader.display_name
    assert_equal 'Andrew', @reader.first_name
    assert_equal 'vonderLuft', @reader.last_name
  end

  def test_readers_sort_by_first_name_case_insensitively
    @reader.update!(display_name: 'anastasia Fomenko')
    assert_equal 'anastasia fomenko', @reader.sort_name

    other = Bible270::Reader.create!(provider: 'email', uid: 'z@example.org', email: 'z@example.org',
                                     display_name: 'Zeke Adams')
    assert_operator @reader.sort_name, :<, other.sort_name
  end

  def test_an_admin_can_move_a_reader_to_a_given_day
    today = Date.new(2026, 9, 6)
    @reader.restart_on!(day: 42, on: today)

    assert_equal today - 41, @reader.started_on
    assert_equal 42, Bible270::Plan.day_for(today, @reader.started_on)
  end

  def test_a_start_date_can_be_set_and_cleared
    assert @reader.set_start_date!('2026-09-06')
    assert_equal Date.new(2026, 9, 6), @reader.started_on

    refute @reader.set_start_date!('not a date')
  end

  def test_finding_a_reader_by_email_is_case_and_space_insensitive
    found = Bible270::Reader.from_email('  A@Example.org ')

    assert_equal @reader.id, found.id, 'should find the existing reader, not make a second'
    assert_equal 1, Bible270::Reader.count
  end

  def test_email_readers_are_recognised_for_a_closed_run
    assert Bible270::Reader.email_reader_exists?('a@example.org')
    refute Bible270::Reader.email_reader_exists?('nobody@example.org')
  end

private

  def create_named_reader(first, last, suffix: Bible270::Reader.count)
    uid = "#{first}.#{last}.#{suffix}@example.org".downcase
    Bible270::Reader.create!(provider: 'email', uid: uid, email: uid,
                             display_name: "#{first} #{last}", first_name: first, last_name: last)
  end
end
