# frozen_string_literal: true

require 'test_helper'

# Bible270.today is defined in the entry point, so this requires it explicitly:
# relying on another test file having loaded it made the result depend on order.
require 'bible270'
class TodayTest < Minitest::Test
  def teardown
    Bible270.config.time_zone = nil
  end

  def test_it_follows_the_machine_by_default
    Bible270.config.time_zone = nil

    assert_equal Date.today, Bible270.today
  end

  # A reader whose server runs in UTC but who lives in Los Angeles would otherwise
  # be shown the next day's reading from 4pm.
  def test_the_machine_clock_is_not_utc
    require 'date'
    previous = ENV.fetch('TZ', nil)
    ENV['TZ'] = 'America/Los_Angeles'

    assert_equal Date.today, Bible270.today, 'should track the machine, whatever its zone'
  ensure
    ENV['TZ'] = previous
  end

  def test_a_blank_zone_is_treated_as_unset
    ['', '   ', nil].each do |value|
      Bible270.config.time_zone = value
      assert_equal Date.today, Bible270.today, "#{value.inspect} should mean the system clock"
    end
  end

  def test_an_unknown_zone_falls_back_rather_than_raising
    Bible270.config.time_zone = 'Mars/Olympus_Mons'

    assert_equal Date.today, Bible270.today
  end
end

class LocalTimeTest < Minitest::Test
  def teardown
    Bible270.config.time_zone = nil
    ENV['TZ'] = @previous_tz
  end

  def setup
    @previous_tz = ENV.fetch('TZ', nil)
    Bible270.config.time_zone = nil
  end

  # 00:30 UTC is the previous evening on the American west coast, which is how a
  # reflection written at 5:30pm came to be dated the next day.
  def test_a_stored_timestamp_is_shown_in_the_machines_zone
    ENV['TZ'] = 'America/Los_Angeles'
    utc = Time.utc(2026, 8, 6, 0, 30)

    local = Bible270.local_time(utc)

    assert_equal 5, local.day
    assert_equal 17, local.hour
  end

  def test_the_same_moment_elsewhere
    ENV['TZ'] = 'Pacific/Auckland'
    utc = Time.utc(2026, 8, 6, 0, 30)

    assert_equal 6, Bible270.local_time(utc).day
  end

  def test_a_configured_zone_wins_over_the_machine
    ENV['TZ'] = 'UTC'
    Bible270.config.time_zone = 'America/Los_Angeles'

    skip 'ActiveSupport unavailable' unless Time.respond_to?(:find_zone) && Time.find_zone('America/Los_Angeles')

    assert_equal 5, Bible270.local_time(Time.utc(2026, 8, 6, 0, 30)).day
  end

  def test_an_unknown_zone_falls_back_to_the_machine
    ENV['TZ'] = 'America/Los_Angeles'
    Bible270.config.time_zone = 'Mars/Olympus_Mons'

    assert_equal 5, Bible270.local_time(Time.utc(2026, 8, 6, 0, 30)).day
  end

  def test_nothing_in_nothing_out
    assert_nil Bible270.local_time(nil)
  end

  # today is expressed through local_time, so the two cannot drift apart.
  def test_today_agrees_with_local_time
    ENV['TZ'] = 'America/Los_Angeles'

    assert_equal Bible270.local_time(Time.now).to_date, Bible270.today
  end
end
