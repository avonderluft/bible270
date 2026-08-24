# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class SettingTest < Minitest::Test
    S = Bible270::Setting

    def setup
      needs_rails!
      clear_engine_tables!
      @previous = {
        enrollment_open: Bible270.config.enrollment_open,
        start_date: Bible270.config.start_date
      }
    end

    def teardown
      Bible270.config.enrollment_open = @previous[:enrollment_open]
      Bible270.config.start_date = @previous[:start_date]
      return unless RAILS_LOADED

      S.open_enrollment!
      S.clear_run_start_date!
    end

    def test_reading_a_key_that_was_never_written
      assert_nil S.read('nothing_here')
    end

    def test_writing_then_reading
      S.write('greeting', 'hello')
      assert_equal 'hello', S.read('greeting')
    end

    def test_writing_the_same_key_twice_updates_rather_than_duplicates
      S.write('greeting', 'hello')
      S.write('greeting', 'again')

      assert_equal 'again', S.read('greeting')
      assert_equal 1, S.where(key: 'greeting').count
    end

    def test_deleting_a_key
      S.write('temporary', 'x')
      S.delete_key('temporary')

      assert_nil S.read('temporary')
    end

    def test_run_start_date_uses_the_configured_date_by_default
      Bible270.config.start_date = Date.new(2026, 9, 6)

      assert_equal Date.new(2026, 9, 6), S.run_start_date
      refute S.run_start_date_overridden?
    end

    def test_an_admin_date_overrides_configuration
      Bible270.config.start_date = Date.new(2026, 9, 6)

      assert S.set_run_start_date!('2026-08-02')
      assert_equal Date.new(2026, 8, 2), S.run_start_date
      assert S.run_start_date_overridden?
    end

    def test_an_invalid_run_start_date_is_refused
      refute S.set_run_start_date!('not a date')
      refute S.run_start_date_overridden?
    end

    def test_a_malformed_stored_override_falls_back_without_claiming_to_be_active
      Bible270.config.start_date = Date.new(2026, 9, 6)
      S.write(S::RUN_START_DATE, 'not a date')

      assert_equal Date.new(2026, 9, 6), S.run_start_date
      refute S.run_start_date_overridden?
    end

    def test_clearing_the_override_restores_configuration
      Bible270.config.start_date = Date.new(2026, 9, 6)
      S.set_run_start_date!('2026-08-02')

      S.clear_run_start_date!

      assert_equal Date.new(2026, 9, 6), S.run_start_date
      refute S.run_start_date_overridden?
    end

    def test_a_run_is_open_by_default
      refute S.enrollment_closed?
      assert_nil S.enrollment_closed_at
    end

    def test_closing_and_reopening
      S.close_enrollment!
      assert S.enrollment_closed?
      refute_nil S.enrollment_closed_at

      S.open_enrollment!
      refute S.enrollment_closed?
      assert_nil S.enrollment_closed_at
    end

    def test_the_closing_time_is_recorded
      moment = Time.current
      S.close_enrollment!(at: moment)

      assert_in_delta moment.to_i, S.enrollment_closed_at.to_i, 1
    end

    def test_an_unparseable_stored_time_does_not_raise
      S.write(S::ENROLLMENT_CLOSED_AT, 'not a time')

      assert S.enrollment_closed?, 'any value still means closed'
      assert_nil S.enrollment_closed_at
    end

    # config.enrollment_open = false launches a run closed, with no row written.
    def test_configuration_can_launch_closed
      Bible270.config.enrollment_open = false

      assert S.enrollment_closed?
      assert_nil S.enrollment_closed_at, 'nobody closed it, so there is no timestamp'
    end
  end
end
