# frozen_string_literal: true

require 'test_helper'
require 'bible270'
require 'bible270/reader_consistency'

class ReaderConsistencyTest < Minitest::Test
  def setup
    needs_rails!
    clear_engine_tables!
    @previous_config = %i[start_date allow_reader_start_date time_zone].to_h do |key|
      [key, Bible270.config.public_send(key)]
    end
    @start = Date.new(2026, 1, 1)
    @today = @start + 7
    @sequence = 0
    Bible270.config.start_date = @start
    Bible270.config.allow_reader_start_date = true
    Bible270.config.time_zone = 'UTC'
  end

  def teardown
    @previous_config&.each { |key, value| Bible270.config.public_send("#{key}=", value) }
  end

  def test_daily_on_track_reading_has_an_exact_baseline_score
    reader = create_reader
    complete_daily(reader, 7)

    result = consistency(reader)

    assert_result result, score: Rational(100), percentage: Rational(100), days: 7
    assert_kind_of Rational, result.score
    assert_kind_of Rational, result.on_track_percentage
    assert result.ranked?
    refute result.provisional?
  end

  def test_always_one_day_ahead
    reader = create_reader
    complete(reader, 1, at: timestamp(@start - 1))
    (2..8).each { |day| complete(reader, day, at: timestamp(@start + day - 2)) }

    assert_result consistency(reader), score: Rational(105), percentage: Rational(100), days: 7
  end

  def test_ahead_bonus_is_capped_at_seven_days
    reader = create_reader
    (1..20).each { |day| complete(reader, day, at: timestamp(@start)) }

    assert_result consistency(reader), score: Rational(135), percentage: Rational(100), days: 7
  end

  def test_behind_penalty_is_not_capped_or_clamped_to_zero
    reader = create_reader

    assert_result consistency(reader, today: @start + 21), score: Rational(-10), percentage: Rational(0), days: 21
  end

  def test_sustained_reading_beats_catching_up_to_the_same_current_progress
    steady = create_reader
    catchup = create_reader
    complete_daily(steady, 7)
    (1..7).each { |day| complete(catchup, day, at: timestamp(@today - 1)) }
    calculator = Bible270::ReaderConsistency.new(readers: [steady, catchup], today: @today)

    assert_equal steady.days_completed, catchup.days_completed
    assert_result calculator.for(steady), score: Rational(100), percentage: Rational(100), days: 7
    assert_result calculator.for(catchup), score: Rational(70), percentage: Rational(100, 7), days: 7
    assert_operator calculator.for(steady).score, :>, calculator.for(catchup).score
  end

  def test_partial_days_do_not_count_and_completion_waits_for_the_last_part
    reader = create_reader
    complete(reader, 1, at: timestamp(@start))
    reader.checkoffs.where(day: 1).first.update!(created_at: timestamp(@start + 1))
    complete(reader, 2, at: timestamp(@start))
    reader.checkoffs.where(day: 2).first.destroy!

    # No full day on the first evening, one full day on the second: both are one behind.
    assert_result consistency(reader, today: @start + 2), score: Rational(90), percentage: Rational(0), days: 2
  end

  def test_a_last_part_added_today_does_not_complete_yesterdays_reading
    reader = create_reader
    complete(reader, 1, at: timestamp(@start))
    reader.checkoffs.where(day: 1).first.update!(created_at: timestamp(@start + 1))

    assert_result consistency(reader, today: @start + 1), score: Rational(90), percentage: Rational(0), days: 1
  end

  def test_out_of_order_plan_days_count_as_days_not_the_highest_day_number
    reader = create_reader
    complete(reader, 40, at: timestamp(@start + 1))
    complete(reader, Bible270::Plan::DAYS, at: timestamp(@start))

    assert_result consistency(reader, today: @start + 2), score: Rational(100), percentage: Rational(100), days: 2
  end

  def test_personal_and_shared_start_dates_in_the_same_collection
    shared = create_reader
    personal = create_reader(start_date: @start + 5)
    complete(shared, 1, at: timestamp(@start))
    complete(personal, 1, at: timestamp(@start + 5))
    calculator = Bible270::ReaderConsistency.new(readers: [shared, personal], today: @today)

    assert_result calculator.for(shared), score: Rational(70), percentage: Rational(100, 7), days: 7
    assert_result calculator.for(personal), score: Rational(95), percentage: Rational(50), days: 2
  end

  def test_personal_dates_are_ignored_when_disabled
    reader = create_reader(start_date: @start + 5)
    Bible270.config.allow_reader_start_date = false

    assert_result consistency(reader), score: Rational(60), percentage: Rational(0), days: 7
  end

  def test_runtime_shared_start_date_overrides_configuration
    reader = create_reader
    Bible270::Setting.set_run_start_date!(@start + 5)

    assert_result consistency(reader), score: Rational(85), percentage: Rational(0), days: 2
  end

  def test_late_creation_shortens_the_window_without_resetting_the_expected_plan_day
    reader = create_reader(created_at: timestamp(@start + 4))

    assert_result consistency(reader), score: Rational(40), percentage: Rational(0), days: 3
  end

  def test_completions_before_the_evaluation_window_carry_forward
    reader = create_reader(created_at: timestamp(@start + 4))
    (1..5).each { |day| complete(reader, day, at: timestamp(@start + 3)) }

    assert_result consistency(reader), score: Rational(90), percentage: Rational(100, 3), days: 3
  end

  def test_only_completed_evenings_count_not_today_or_future_checkoffs
    reader = create_reader
    complete(reader, 1, at: Time.utc(2026, 1, 1, 23, 59, 59, 999_999))
    complete(reader, 2, at: Time.utc(2026, 1, 2))
    complete(reader, 3, at: timestamp(@start + 10))

    assert_result consistency(reader, today: @start + 1), score: Rational(100), percentage: Rational(100), days: 1
  end

  def test_default_today_comes_from_bible270
    reader = create_reader

    Bible270.stub(:today, @start + 1) do
      result = Bible270::ReaderConsistency.new(readers: [reader]).for(reader)
      assert_result result, score: Rational(90), percentage: Rational(0), days: 1
    end
  end

  def test_undated_future_and_not_yet_completed_evenings_are_unranked
    Bible270.config.start_date = nil
    readers = [
      create_reader,
      create_reader(start_date: @today + 1),
      create_reader(start_date: @today),
      create_reader(start_date: @start, created_at: timestamp(@today)),
      create_reader(start_date: @start, created_at: timestamp(@today + 1)),
      create_reader(start_date: @start - Bible270::Plan::DAYS, created_at: timestamp(@start))
    ]
    calculator = Bible270::ReaderConsistency.new(readers: readers, today: @today)

    readers.each do |reader|
      result = calculator.for(reader)
      assert_nil result.score
      assert_nil result.on_track_percentage
      assert_equal 0, result.days_evaluated
      refute result.ranked?
      refute result.provisional?
      assert_equal 2, result.sort_key(reader).first
    end
  end

  def test_ended_plan_stops_evaluation_and_later_completions_do_not_change_its_score
    last = @start + Bible270::Plan::DAYS - 1
    reader = create_reader(created_at: timestamp(last))
    complete(reader, 1, at: timestamp(last))
    before = consistency(reader, today: last + 1)
    complete(reader, 2, at: timestamp(last + 1))
    after = consistency(reader, today: last + 30)

    assert_result before, score: Rational(-2590), percentage: Rational(0), days: 1
    assert_equal before, after
  end

  def test_a_full_plan_window_is_bounded_to_plan_days
    reader = create_reader

    assert_result consistency(reader, today: @start + 500), score: Rational(-1255), percentage: Rational(0), days: 270
  end

  def test_local_midnight_and_spring_dst_apply_to_creation_and_completion
    assert_local_evenings(
      start: Date.new(2026, 3, 7),
      created_at: Time.utc(2026, 3, 8, 7, 30),
      completions: [Time.utc(2026, 3, 8, 7, 59, 59), Time.utc(2026, 3, 9, 6, 59, 59), Time.utc(2026, 3, 9, 7)]
    )
  end

  def test_local_midnight_and_fall_dst_apply_to_creation_and_completion
    assert_local_evenings(
      start: Date.new(2026, 10, 31),
      created_at: Time.utc(2026, 11, 1, 6, 30),
      completions: [Time.utc(2026, 11, 1, 6, 59, 59), Time.utc(2026, 11, 2, 7, 59, 59), Time.utc(2026, 11, 2, 8)]
    )
  end

  def test_six_evenings_are_provisional_and_seven_are_established
    reader = create_reader
    six = consistency(reader, today: @start + 6)
    seven = consistency(reader, today: @start + 7)

    assert six.ranked?
    assert six.provisional?
    assert_equal 1, six.sort_key(reader).first
    assert seven.ranked?
    refute seven.provisional?
    assert_equal 0, seven.sort_key(reader).first
  end

  def test_unchecking_reconstructs_history_from_the_surviving_records
    reader = create_reader
    complete_daily(reader, 7)
    assert_equal Rational(100), consistency(reader).score

    reader.checkoffs.where(day: 1).first.destroy!

    assert_result consistency(reader), score: Rational(90), percentage: Rational(0), days: 7
  end

  def test_changed_start_dates_recompute_history_using_the_current_date
    reader = create_reader(start_date: @start)
    complete_daily(reader, 7)
    assert_equal Rational(100), consistency(reader).score

    reader.set_start_date!(@start + 1)

    assert_result consistency(reader), score: Rational(105), percentage: Rational(100), days: 6
  end

  def test_two_bulk_aggregates_for_only_selected_readers_regardless_of_collection_size
    readers = Array.new(8) { create_reader }
    outsider = create_reader
    (readers + [outsider]).each { |reader| complete(reader, 1, at: timestamp(@start)) }

    [readers.first(1), readers].each do |selected|
      queries = capture_selects do
        calculator = Bible270::ReaderConsistency.new(readers: selected, today: @today)
        2.times do
          selected.each do |reader|
            result = calculator.for(reader)
            assert_equal Rational(70), result.score
            result.sort_key(reader)
          end
        end
      end
      checkoff_queries = queries.select { |query| query[:sql].include?('bible270_checkoffs') }
      assert_equal 2, checkoff_queries.length
      assert_match(%r{COUNT\(}i, checkoff_queries[0][:sql])
      assert_match(%r{MAX\(.*created_at}i, checkoff_queries[1][:sql])
      checkoff_queries.each do |query|
        ids = query[:binds].select { |bind| bind.name == 'reader_id' }.map(&:value_for_database)
        assert_equal selected.map(&:id).sort, ids.sort
        refute_includes ids, outsider.id
        assert_match(%r{GROUP BY.*reader_id.*day}i, query[:sql])
      end
      assert_equal(1, queries.count { |query| query[:sql].match?(%r{FROM "bible270_settings"}) })
    end
  end

  def test_a_day_removed_between_aggregates_is_not_credited_and_does_not_crash
    reader = create_reader
    complete(reader, 1, at: timestamp(@start))
    removed = false
    subscriber = ->(_name, _start, _finish, _id, payload) do
      next if removed || !payload[:sql].match?(%r{SELECT COUNT.*bible270_checkoffs}i)

      removed = true
      reader.clear_day!(1)
    end

    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
      assert_result consistency(reader, today: @start + 1), score: Rational(90), percentage: Rational(0), days: 1
    end
    assert removed
  end

  def test_empty_collection_does_not_query
    queries = capture_selects { Bible270::ReaderConsistency.new(readers: [], today: @today) }

    assert_empty queries
  end

private

  def create_reader(start_date: nil, created_at: timestamp(@start - 1))
    @sequence += 1
    email = "consistency#{@sequence}@example.org"
    Bible270::Reader.create!(provider: 'email', uid: email, email: email,
                             display_name: "Reader #{@sequence}", started_on: start_date, created_at: created_at)
  end

  def timestamp(date)
    Time.utc(date.year, date.month, date.day, 12)
  end

  def complete(reader, day, at:)
    reader.mark_day_complete!(day)
    reader.checkoffs.where(day: day).update_all(created_at: at)
  end

  def complete_daily(reader, days)
    (1..days).each { |day| complete(reader, day, at: timestamp(@start + day - 1)) }
  end

  def consistency(reader, today: @today)
    Bible270::ReaderConsistency.new(readers: [reader], today: today).for(reader)
  end

  def assert_result(result, score:, percentage:, days:)
    assert_equal score, result.score
    assert_equal percentage, result.on_track_percentage
    assert_equal days, result.days_evaluated
  end

  def assert_local_evenings(start:, created_at:, completions:)
    Bible270.config.time_zone = 'America/Los_Angeles'
    reader = create_reader(start_date: start, created_at: created_at)
    completions.each_with_index { |at, index| complete(reader, index + 1, at: at) }

    assert_result consistency(reader, today: start + 2), score: Rational(100), percentage: Rational(100), days: 2
  end

  def capture_selects(&block)
    queries = []
    subscriber = ->(_name, _start, _finish, _id, payload) do
      queries << payload if payload[:sql].match?(%r{\ASELECT}i)
    end
    Bible270::Checkoff.uncached do
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &block)
    end
    queries
  end
end

class ReaderConsistencyResultTest < Minitest::Test
  Reader = Struct.new(:sort_name, :id)

  def test_sort_key_preserves_exact_values_and_uses_every_tiebreaker
    reader = Reader.new('reader', 4)
    result = build_result(score: Rational(301, 3), percentage: Rational(200, 3), days: 7)

    assert_equal [0, Rational(-301, 3), Rational(-200, 3), -7, 'reader', 4], result.sort_key(reader)
    # These scores round to the same displayed tenth but must not sort as equal.
    higher = build_result(score: Rational(10_034, 100), percentage: 0, days: 7)
    assert_before higher.sort_key(reader), result.sort_key(reader)

    tied = build_result(score: Rational(602, 6), percentage: Rational(200, 3), days: 7)
    assert_equal result.sort_key(reader), tied.sort_key(reader)
    more_on_track = build_result(score: result.score, percentage: 100, days: 7)
    assert_before more_on_track.sort_key(reader), result.sort_key(reader)
    longer = build_result(score: result.score, percentage: result.on_track_percentage, days: 8)
    assert_before longer.sort_key(reader), result.sort_key(reader)
    assert_before result.sort_key(Reader.new('aardvark', 9)), result.sort_key(reader)
    assert_before result.sort_key(Reader.new('reader', 3)), result.sort_key(reader)
  end

  def test_groups_precede_scores_and_unranked_readers_sort_by_name_then_id
    reader = Reader.new('reader', 1)
    established = build_result(score: -500, percentage: 0, days: 7)
    provisional = build_result(score: 135, percentage: 100, days: 6)
    unranked = build_result(score: nil, percentage: nil, days: 0)

    assert_before established.sort_key(reader), provisional.sort_key(reader)
    assert_before provisional.sort_key(reader), unranked.sort_key(reader)
    assert_equal [2, 0, 0, 0, 'reader', 1], unranked.sort_key(reader)
    assert_before unranked.sort_key(Reader.new('aardvark', 9)), unranked.sort_key(reader)
    assert_before unranked.sort_key(reader), unranked.sort_key(Reader.new('reader', 2))
  end

private

  def build_result(score:, percentage:, days:)
    Bible270::ReaderConsistency::Result.new(score: score, on_track_percentage: percentage, days_evaluated: days)
  end

  def assert_before(left, right)
    assert_equal(-1, left <=> right)
  end
end
