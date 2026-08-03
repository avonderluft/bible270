# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class SettingTest < Minitest::Test
    S = Bible270::Setting

    def setup
      needs_rails!
      clear_engine_tables!
      @previous = Bible270.config.enrollment_open
    end

    def teardown
      Bible270.config.enrollment_open = @previous
      S.open_enrollment! if RAILS_LOADED
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
