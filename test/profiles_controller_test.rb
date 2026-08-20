# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class ProfilesControllerTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_daily_reminders = Bible270.config.daily_reminders
      Bible270.config.daily_reminders = false
      @reader = Bible270::Reader.create!(provider: 'email', uid: 'r@example.org',
                                         email: 'r@example.org', display_name: 'R Reader',
                                         first_name: 'R', last_name: 'Reader')
    end

    def teardown
      Bible270.config.daily_reminders = @previous_daily_reminders
    end

    def mount = Bible270.config.mount_at.chomp('/')

    def sign_in_as(reader)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"
    end

    def test_a_visitor_is_sent_to_sign_in
      get "#{mount}/profile"

      assert_response :redirect
      assert_match(%r{sign_in}, response.location)
    end

    def test_a_reader_sees_the_form
      sign_in_as(@reader)
      get "#{mount}/profile"

      assert_response :success
      assert_select 'p.b270-eyebrow', text: 'Profile'
      assert_select 'h1', text: 'Your details'
      assert_match(%r{first_name}, response.body)
      assert_match(%r{last_name}, response.body)
      refute_match(%r{Email me when someone mentions}, response.body)
      refute_match(%r{name="notify_on_mention"}, response.body)
      refute_match(%r{name="daily_reminders"}, response.body)
      refute_match(%r{name="daily_reminder_time"}, response.body)
      assert_match(%r{name="bible_version".*class="b270-source-choices"}m, response.body,
                   'reader choice belongs immediately below the translation selector')
      assert_equal 2, response.body.scan(%r{name="passage_source"}).size
      assert_match(%r{value="bible_gateway" checked="checked"}, response.body)
    end

    def test_original_languages_fix_the_source_to_blue_letter_bible
      @reader.update_bible_version('HEB/GRK')
      sign_in_as(@reader)
      get "#{mount}/profile"

      blue_letter = response.body.match(%r{<input[^>]*value="blue_letter_bible"[^>]*>}).to_s
      gateway = response.body.match(%r{<input[^>]*value="bible_gateway"[^>]*>}).to_s
      assert_includes blue_letter, 'checked="checked"'
      assert_includes blue_letter, 'disabled="disabled"'
      refute_includes gateway, 'checked="checked"'
      assert_includes gateway, 'disabled="disabled"'
    end

    def test_a_name_can_be_changed
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'Andrew', last_name: 'vonderLuft' }

      assert_response :redirect
      @reader.reload
      assert_equal 'Andrew', @reader.first_name
      assert_equal 'vonderLuft', @reader.last_name
      assert_equal 'Andrew vonderLuft', @reader.display_name
    end

    def test_daily_reminder_checkbox_is_shown_only_when_globally_enabled
      Bible270.config.daily_reminders = true
      @reader.update!(daily_reminders: true)
      sign_in_as(@reader)

      get "#{mount}/profile"

      assert_response :success
      assert_select '.b270-reminder-row' do
        assert_select 'label.b270-reminder-optin input[name="daily_reminders"][checked="checked"]'
        assert_select '.b270-reminder-time .b270-time-control[role="group"][aria-describedby="daily-reminder-time-hint"]' do
          assert_select 'select.b270-time-select[name="daily_reminder_hour"][aria-label="Hour"] option[selected="selected"]', text: '08'
          assert_select 'select.b270-time-select[name="daily_reminder_minute"][aria-label="Minute"] option[selected="selected"]', text: '00'
          assert_select '#daily-reminder-time-hint[role="tooltip"]', text: /Uses the plan's configured time zone/
        end
      end
      assert_match(%r{Email me each day's readings}, response.body)
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

    def test_saving_the_profile_preserves_the_existing_mention_notice_setting
      @reader.update!(notify_on_mention: false)
      sign_in_as(@reader)

      patch "#{mount}/profile", params: { first_name: 'R', last_name: 'Reader' }

      refute @reader.reload.notify_on_mention
    end

    def test_half_a_name_is_refused_and_the_form_comes_back
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'Andrew', last_name: '' }

      assert_response :unprocessable_entity
      assert_equal 'R', @reader.reload.first_name, 'nothing should have changed'
    end

    def test_a_translation_can_be_chosen
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'R', last_name: 'Reader', bible_version: 'LSB' }

      assert_equal 'LSB', @reader.reload.bible_version
      assert_equal 'LSB', @reader.effective_bible_version
    end

    def test_blue_letter_bible_can_be_chosen
      sign_in_as(@reader)
      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', bible_version: 'LSB', passage_source: 'blue_letter_bible'
      }

      assert_equal 'blue_letter_bible', @reader.reload.passage_source
    end

    def test_an_unknown_passage_source_is_refused
      sign_in_as(@reader)
      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', bible_version: 'LSB', passage_source: 'unknown'
      }

      assert_response :unprocessable_entity
      assert_equal 'bible_gateway', @reader.reload.passage_source
    end

    def test_omitting_the_passage_source_returns_to_the_default
      @reader.update!(passage_source: 'blue_letter_bible')
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'R', last_name: 'Reader', bible_version: 'LSB' }

      assert_equal 'bible_gateway', @reader.reload.passage_source
    end

    def test_an_unknown_translation_is_refused
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'R', last_name: 'Reader', bible_version: 'NIV' }

      assert_response :unprocessable_entity
      assert_nil @reader.reload.bible_version
    end

    # Reading links should open in whatever the reader chose.
    def test_the_chosen_translation_reaches_the_day_page
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'R', last_name: 'Reader', bible_version: 'KJV' }
      get "#{mount}/day/1"

      assert_response :success
      assert_match(%r{\(KJV\)}, response.body)
      assert_match(%r{biblegateway\.com}, response.body)
    end

    def test_the_blue_letter_bible_choice_reaches_the_day_page
      sign_in_as(@reader)
      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', bible_version: 'KJV', passage_source: 'blue_letter_bible'
      }
      get "#{mount}/day/1"

      assert_response :success
      assert_match(%r{blueletterbible\.org/kjv/gen/1/1/s_1001}, response.body)
      refute_match(%r{biblegateway\.com}, response.body)
    end

    def test_a_picture_can_be_removed
      skip 'Active Storage unavailable' unless Bible270::Reader.avatar_uploads?

      @reader.avatar.attach(io: StringIO.new('x'), filename: 'a.png', content_type: 'image/png')
      assert @reader.reload.avatar_uploaded?

      sign_in_as(@reader)
      delete "#{mount}/profile/avatar"

      refute @reader.reload.avatar_uploaded?
    end

    def test_a_visitor_cannot_remove_a_picture
      delete "#{mount}/profile/avatar"

      assert_response :redirect
      assert_match(%r{sign_in}, response.location)
    end
  end
end
