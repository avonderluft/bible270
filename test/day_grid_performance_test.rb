# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class DayGridPerformanceTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_start_date = Bible270.config.start_date
      @previous_allow_reader_start_date = Bible270.config.allow_reader_start_date
      Bible270.config.start_date = nil
      Bible270.config.allow_reader_start_date = true
      @reader = create_reader('grid@example.org')
    end

    def teardown
      Bible270.config.start_date = @previous_start_date
      Bible270.config.allow_reader_start_date = @previous_allow_reader_start_date
    end

    def test_warm_profile_setting_queries_are_bounded_with_all_270_links
      start_date = Date.new(2020, 1, 1)
      Bible270::Setting.set_run_start_date!(start_date)
      sign_in_as(@reader)
      get "#{mount}/profile"
      assert_response :success

      queries = 0
      # Count cache hits too: cached SELECTs still allocate and resolve settings.
      counter = ->(*, payload) do
        sql = payload[:sql].to_s
        queries += 1 if sql.match?(%r{\ASELECT\b}i) && sql.include?('bible270_settings')
      end
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        get "#{mount}/profile"
      end

      assert_grid_calendar(start_date)
      assert_operator queries, :>, 0, 'the request must still read live settings'
      assert_operator queries, :<=, 8, "#{queries} setting SELECT events for one 270-day grid"
    end

    def test_selected_reader_grid_uses_their_personal_calendar
      Bible270::Setting.set_run_start_date!(Date.new(2020, 1, 1))
      @reader.set_start_date!(Date.new(2020, 2, 1))
      selected_reader = create_reader('selected@example.org')
      personal_start = Date.new(2020, 3, 1)
      selected_reader.set_start_date!(personal_start)
      sign_in_as(@reader)

      get "#{mount}/readers/#{selected_reader.id}"

      assert_grid_calendar(personal_start)
    end

    def test_alumni_grid_keeps_its_frozen_calendar_when_shared_settings_change
      frozen_start = Date.new(2020, 1, 1)
      Bible270::Setting.set_run_start_date!(frozen_start)
      @reader.archive!
      sign_in_as(@reader)
      get "#{mount}/profile"
      assert_grid_calendar(frozen_start)

      Bible270::Setting.set_run_start_date!(Date.new(2021, 1, 1))
      get "#{mount}/profile"

      assert_grid_calendar(frozen_start)
    end

    def test_alumni_grid_keeps_an_explicitly_undated_snapshot
      @reader.archive!
      sign_in_as(@reader)
      Bible270::Setting.set_run_start_date!(Date.new(2021, 1, 1))

      get "#{mount}/profile"

      assert_grid_calendar(nil)
    end

    def test_shared_calendar_changes_between_requests_update_every_grid_label
      sign_in_as(@reader)
      get "#{mount}/profile"
      assert_grid_calendar(nil)

      [Date.new(2020, 1, 1), Date.new(2021, 2, 1)].each do |start_date|
        Bible270::Setting.set_run_start_date!(start_date)
        get "#{mount}/profile"
        assert_grid_calendar(start_date)
      end

      Bible270::Setting.clear_run_start_date!
      get "#{mount}/profile"
      assert_grid_calendar(nil)
    end

  private

    def mount = Bible270.config.mount_at.chomp('/')

    def create_reader(email)
      Bible270::Reader.create!(provider: 'email', uid: email, email: email,
                               display_name: 'Grid Reader', first_name: 'Grid', last_name: 'Reader')
    end

    def sign_in_as(reader)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"
    end

    def assert_grid_calendar(start_date)
      assert_response :success
      cells = css_select('.b270-grid a.b270-cell')
      days = (1..Bible270::Plan::DAYS).to_a
      assert_equal 270, cells.size
      assert_equal days.map(&:to_s), cells.map(&:text)
      assert_equal(days.map { |day| "#{mount}/day/#{day}" }, cells.map { |cell| cell['href'] })
      expected_labels = days.map do |day|
        parts = ["Day #{day}"]
        parts << (start_date + day - 1).strftime('%A, %B %-d, %Y') if start_date
        parts << 'not read'
        parts << Bible270::Plan.readings_for(day).values.compact.join(' · ')
        parts.join('. ')
      end
      assert_equal(expected_labels, cells.map { |cell| cell['aria-label'] })
    end
  end
end
