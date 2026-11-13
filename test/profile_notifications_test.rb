# frozen_string_literal: true

require_relative 'support/profiles_controller_test_case'

if RAILS_LOADED
  class ProfileNotificationsTest < Bible270ProfilesControllerTestCase
    def test_profile_stays_available_while_the_daily_reminder_migration_is_pending
      Bible270.config.daily_reminders = true
      sign_in_as(@reader)

      Bible270::Reader.stub(:daily_reminder_columns?, false) do
        get "#{mount}/profile"

        assert_response :success
        assert_select 'input[name="daily_reminders"]', count: 0
        assert_select 'select[name="daily_reminder_hour"]', count: 0
        assert_select 'select[name="daily_reminder_minute"]', count: 0
        assert_select '.b270-flash.alert', text: %r{temporarily unavailable.*database update}i

        patch "#{mount}/profile", params: { first_name: 'Ready', last_name: 'Reader' }

        assert_response :redirect
      end

      @reader.reload
      assert_equal 'Ready', @reader.first_name
      assert_equal 'Reader', @reader.last_name
    end

    def test_profile_stays_available_while_the_comment_notification_migration_is_pending
      sign_in_as(@reader)

      Bible270::Reader.stub(:comment_notification_columns?, false) do
        get "#{mount}/profile"
        assert_response :success
        assert_select 'input[name="comment_notifications"]', count: 0
        assert_select '.b270-flash.alert', text: %r{Reflection email settings.*database update}i

        patch "#{mount}/profile", params: {
          first_name: 'Ready', last_name: 'Reader', comment_notifications: 'all'
        }
        assert_response :redirect
      end

      assert_equal 'all', @reader.reload.comment_notification_level
    end

    def test_daily_reminder_checkbox_is_shown_only_when_globally_enabled
      Bible270.config.daily_reminders = true
      @reader.update!(daily_reminders: true)
      sign_in_as(@reader)

      get "#{mount}/profile"

      assert_response :success
      assert_select '.b270-reminder-row' do
        assert_select 'label.b270-reminder-optin input[name="daily_reminders"][checked="checked"][aria-describedby="daily-reminder-optin-hint"]'
        assert_select '#daily-reminder-optin-hint[role="tooltip"]', text: %r{Uses the plan's time zone:}
        assert_select '.b270-reminder-time .b270-time-control[role="group"][aria-describedby="daily-reminder-time-hint"]' do
          assert_select 'select.b270-time-select[name="daily_reminder_hour"][aria-label="Hour"] option[selected="selected"]', text: '08'
          assert_select 'select.b270-time-select[name="daily_reminder_minute"][aria-label="Minute"] option[selected="selected"]', text: '00'
          assert_select '#daily-reminder-time-hint[role="tooltip"]', text: %r{Uses the plan's time zone:}
        end
      end
      minute_options = css_select('select[name="daily_reminder_minute"] option').map { |option| option['value'] }
      assert_equal %w[00 15 30 45], minute_options
      assert_match(%r{Email me each day's readings}, response.body)
    end

    def test_an_existing_off_quarter_reminder_minute_remains_available
      Bible270.config.daily_reminders = true
      @reader.update!(daily_reminder_time: '08:40')
      sign_in_as(@reader)

      get "#{mount}/profile"

      minute_options = css_select('select[name="daily_reminder_minute"] option').map { |option| option['value'] }
      assert_equal %w[00 15 30 40 45], minute_options
      assert_select 'select[name="daily_reminder_minute"] option[selected="selected"]', text: '40'
    end

    def test_daily_reminder_preference_is_saved_after_a_valid_profile_update
      Bible270.config.daily_reminders = true
      sign_in_as(@reader)

      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', daily_reminders: '1',
        daily_reminder_hour: '06', daily_reminder_minute: '45'
      }

      assert_response :redirect
      @reader.reload
      assert @reader.daily_reminders
      assert_equal '06:45', @reader.daily_reminder_time
    end

    def test_daily_reminder_preference_is_not_saved_when_the_form_is_invalid
      Bible270.config.daily_reminders = true
      sign_in_as(@reader)

      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: '', daily_reminders: '1',
        daily_reminder_hour: '06', daily_reminder_minute: '45'
      }

      assert_response :unprocessable_entity
      @reader.reload
      refute @reader.daily_reminders
      assert_equal '08:00', @reader.daily_reminder_time
      assert_select 'input[name="daily_reminders"][checked="checked"]'
      assert_select 'select[name="daily_reminder_hour"] option[selected="selected"]', text: '06'
      assert_select 'select[name="daily_reminder_minute"] option[selected="selected"]', text: '45'
    end

    def test_invalid_daily_reminder_time_rerenders_with_a_useful_error
      Bible270.config.daily_reminders = true
      sign_in_as(@reader)

      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', daily_reminders: '1', daily_reminder_time: '25:00'
      }

      assert_response :unprocessable_entity
      assert_match(%r{reminder time in 24-hour HH:MM format}, response.body)
      @reader.reload
      refute @reader.daily_reminders
      assert_equal '08:00', @reader.daily_reminder_time
      assert_select 'select[name="daily_reminder_hour"]'
      assert_select 'select[name="daily_reminder_minute"]'
    end

    def test_disabled_daily_reminders_preserve_both_settings_when_parameters_are_posted
      @reader.update!(daily_reminders: true, daily_reminder_time: '06:30')
      sign_in_as(@reader)

      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', daily_reminders: '0', daily_reminder_time: '25:00'
      }

      assert_response :redirect
      @reader.reload
      assert @reader.daily_reminders
      assert_equal '06:30', @reader.daily_reminder_time
    end

    def test_the_reflection_email_preference_can_be_changed
      sign_in_as(@reader)

      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', comment_notifications: 'all'
      }
      assert_equal 'all', @reader.reload.comment_notification_level

      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', comment_notifications: 'none'
      }
      assert_equal 'none', @reader.reload.comment_notification_level

      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', comment_notifications: 'personal'
      }
      assert_equal 'personal', @reader.reload.comment_notification_level
    end

    def test_an_unknown_reflection_email_preference_is_refused
      sign_in_as(@reader)

      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', comment_notifications: 'everything'
      }

      assert_response :unprocessable_entity
      assert_match(%r{reflection email preference from the list}, response.body)
      assert_equal 'all', @reader.reload.comment_notification_level
    end

    def test_omitting_the_reflection_email_preference_preserves_it
      @reader.update_comment_notification_level!('all')
      sign_in_as(@reader)

      patch "#{mount}/profile", params: { first_name: 'R', last_name: 'Reader' }

      assert_equal 'all', @reader.reload.comment_notification_level
    end

    def test_the_reflection_email_preference_is_hidden_and_preserved_when_globally_disabled
      previous = Bible270.config.mention_notifications
      Bible270.config.mention_notifications = false
      @reader.update_comment_notification_level!('all')
      sign_in_as(@reader)

      get "#{mount}/profile"
      assert_select 'input[name="comment_notifications"]', count: 0

      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', comment_notifications: 'none'
      }
      assert_equal 'all', @reader.reload.comment_notification_level
    ensure
      Bible270.config.mention_notifications = previous
    end

    def test_an_omitted_reminder_checkbox_disables_reminders_but_saves_the_time
      Bible270.config.daily_reminders = true
      @reader.update!(daily_reminders: true)
      sign_in_as(@reader)
      patch "#{mount}/profile", params: complete_profile_params.except(:daily_reminders)

      assert_response :redirect
      refute @reader.reload.daily_reminders
      assert_equal '06:45', @reader.daily_reminder_time
    end

    def test_reminder_zone_shows_the_configured_named_zone_even_when_not_opted_in
      Bible270.config.daily_reminders = true
      Bible270.config.time_zone = 'Pacific Time (US & Canada)'
      sign_in_as(@reader)
      Time.use_zone('UTC') do
        get "#{mount}/profile"
      end

      assert_select '#daily-reminder-zone', text: 'Plan time zone: America/Los_Angeles'
      assert_select '#daily-reminder-optin-hint', text: %r{America/Los_Angeles, not your device's time zone}
      assert_equal css_select('#daily-reminder-optin-hint').first.text.strip,
                   css_select('#daily-reminder-time-hint').first.text.strip

      patch "#{mount}/profile", params: complete_profile_params.merge(display_mode: 'invalid')
      assert_response :unprocessable_entity
      assert_select '#daily-reminder-zone', text: 'Plan time zone: America/Los_Angeles'
    end

    def test_reminder_zone_uses_the_machine_fallback_not_rails_default_zone
      previous_tz = ENV.fetch('TZ', nil)
      ENV['TZ'] = 'America/New_York'
      Bible270.config.daily_reminders = true
      sign_in_as(@reader)

      Time.use_zone('UTC') do
        travel_to Time.utc(2026, 7, 1, 12) do
          [nil, '', 'Not/AZone'].each do |zone|
            Bible270.config.time_zone = zone
            get "#{mount}/profile"
            assert_select '#daily-reminder-zone', text: 'Plan time zone: Server time zone — EDT'
            assert_select '#daily-reminder-time-hint', text: %r{Server time zone — EDT, not your device's time zone}
          end
        end
      end
    ensure
      ENV['TZ'] = previous_tz
    end

    def test_reminder_zone_is_hidden_when_reminders_are_disabled_or_migration_is_pending
      sign_in_as(@reader)
      get "#{mount}/profile"
      assert_select '#daily-reminder-zone', count: 0

      Bible270.config.daily_reminders = true
      Bible270::Reader.stub(:daily_reminder_columns?, false) do
        get "#{mount}/profile"
        assert_select '#daily-reminder-zone', count: 0
      end
    end
  end
end
