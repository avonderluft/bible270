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
