# frozen_string_literal: true

require 'test_helper'
require 'tempfile'

if RAILS_LOADED
  class ProfilesControllerTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_time_zone = Bible270.config.time_zone
      @previous_daily_reminders = Bible270.config.daily_reminders
      Bible270.config.daily_reminders = false
      @reader = Bible270::Reader.create!(provider: 'email', uid: 'r@example.org',
                                         email: 'r@example.org', display_name: 'R Reader',
                                         first_name: 'R', last_name: 'Reader')
    end

    def teardown
      Bible270.config.time_zone = @previous_time_zone
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
      assert_match(%r{value="HEB/GRK".*value="ALLGRK"}m, response.body)
      assert_select 'fieldset.b270-notification-field' do
        assert_select 'legend', text: 'Reflection emails'
        assert_select 'input[type="radio"][name="comment_notifications"]', count: 3
        assert_select 'input[value="all"][checked="checked"]', count: 1
        assert_select 'label', text: %r{Every new reflection and reply}
        assert_select 'label', text: %r{Only replies to my reflections and mentions of me}
        assert_select 'label', text: %r{None}
      end
      refute_match(%r{name="daily_reminders"}, response.body)
      refute_match(%r{name="daily_reminder_time"}, response.body)
      assert_match(%r{name="bible_version".*class="b270-source-choices"}m, response.body,
                   'reader choice belongs immediately below the translation selector')
      assert_equal 3, response.body.scan(%r{name="passage_source"}).size
      assert_match(%r{\.b270-source-choices\{.*?flex-wrap:nowrap}m, response.body)
      assert_match(%r{value="bible_com" checked="checked"}, response.body)
      assert_operator response.body.index('Bible.com'), :<, response.body.index('Bible Gateway')
      assert_operator response.body.index('Bible Gateway'), :<, response.body.index('Blue Letter Bible')
      assert_select "a[href='#{mount}/progress']", text: '← Back to your progress'
    end

    def test_display_defaults_to_system_for_readers_and_visitors
      get "#{mount}/sign_in"
      assert_select 'body[data-display-mode="system"]'

      sign_in_as(@reader)
      get "#{mount}/profile"
      assert_select 'body[data-display-mode="system"]'
      assert_select 'label.b270-field > span', text: 'Theme'
      assert_select '#b270-display-hint', text: "System follows your device's setting: Parchment for light, Earth for dark."
      assert_select 'select[name="display_mode"]' do
        assert_select 'option', count: 5
        assert_select 'option[value="light"]', text: 'Parchment'
        assert_select 'option[value="dark"]', text: 'Earth'
        assert_select 'option[value="dark_green"]', text: 'Forest'
        assert_select 'option[value="dark_blue"]', text: 'Midnight'
        assert_select 'option[value="system"][selected]', text: 'System'
      end
    end

    def test_each_display_preference_is_saved_and_applied_on_other_pages
      sign_in_as(@reader)
      %w[dark dark_green dark_blue light system].each do |mode|
        patch "#{mount}/profile", params: { first_name: 'R', last_name: 'Reader', display_mode: mode }
        assert_response :redirect
        assert_equal mode, @reader.reload.display_mode

        follow_redirect!
        assert_select "body[data-display-mode='#{mode}']"
        assert_select "select[name='display_mode'] option[value='#{mode}'][selected]"
        get "#{mount}/progress"
        assert_select "body[data-display-mode='#{mode}']"
      end
    end

    def test_existing_dark_preference_is_shown_as_earth
      @reader.update!(display_mode: 'dark')
      sign_in_as(@reader)
      get "#{mount}/profile"

      assert_select 'body[data-display-mode="dark"]'
      assert_select 'select[name="display_mode"] option[selected]', text: 'Earth'
    end

    def test_omitting_display_preference_preserves_the_saved_choice
      @reader.update!(display_mode: 'dark')
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'R', last_name: 'Reader' }
      assert_response :redirect
      assert_equal 'dark', @reader.reload.display_mode
    end

    def test_invalid_display_preference_is_rejected
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'R', last_name: 'Reader', display_mode: 'sepia' }
      assert_response :unprocessable_entity
      assert_select '.b270-flash.alert', text: %r{a theme from the list}
      assert_equal 'system', @reader.reload.display_mode
    end

    def test_display_preference_is_not_saved_when_other_fields_are_invalid
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'R', last_name: '', display_mode: 'dark' }
      assert_response :unprocessable_entity
      assert_equal 'system', @reader.reload.display_mode
      assert_select 'select[name="display_mode"] option[value="dark"][selected]'
    end

    def test_display_settings_handle_a_pending_migration
      sign_in_as(@reader)
      Bible270::Reader.stub(:display_mode_column?, false) do
        get "#{mount}/profile"
        assert_response :success
        assert_select 'select[name="display_mode"]', count: 0
        assert_select '.b270-flash.alert', text: %r{Theme settings.*database update}
        patch "#{mount}/profile", params: { first_name: 'R', last_name: 'Reader', display_mode: 'dark' }
        assert_response :redirect
      end
      assert_equal 'system', @reader.reload.display_mode
    end

    def test_a_visitor_cannot_change_display_preferences
      patch "#{mount}/profile", params: { display_mode: 'dark' }
      assert_response :redirect
      assert_match(%r{sign_in}, response.location)
      assert_equal 'system', @reader.reload.display_mode
    end

    def test_the_profile_page_expands_the_day_index
      sign_in_as(@reader)

      get "#{mount}/profile"

      assert_select 'details.b270-index[open]' do
        assert_select 'summary', text: 'View all 270 days'
      end
    end

    def test_original_languages_offer_blue_letter_bible_and_bible_com
      @reader.update_bible_version('HEB/GRK')
      sign_in_as(@reader)
      get "#{mount}/profile"

      blue_letter = response.body.match(%r{<input[^>]*value="blue_letter_bible"[^>]*>}).to_s
      bible_com = response.body.match(%r{<input[^>]*value="bible_com"[^>]*>}).to_s
      gateway = response.body.match(%r{<input[^>]*value="bible_gateway"[^>]*>}).to_s
      refute_includes blue_letter, 'checked="checked"'
      refute_includes blue_letter, 'disabled="disabled"'
      assert_includes bible_com, 'checked="checked"'
      refute_includes bible_com, 'disabled="disabled"'
      refute_includes gateway, 'checked="checked"'
      assert_includes gateway, 'disabled="disabled"'
    end

    def test_all_greek_offers_blue_letter_bible_and_bible_com
      @reader.update_bible_version('ALLGRK')
      sign_in_as(@reader)
      get "#{mount}/profile"

      assert_select 'input[name="passage_source"][value="bible_com"][checked="checked"]'
      assert_select 'input[name="passage_source"][value="blue_letter_bible"]:not([disabled])'
      assert_select 'input[name="passage_source"][value="bible_gateway"][disabled="disabled"]'
    end

    def test_a_name_can_be_changed
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'Andrew', last_name: 'vonderLuft' }

      assert_response :redirect
      assert_equal "#{mount}/profile", URI.parse(response.location).path
      @reader.reload
      assert_equal 'Andrew', @reader.first_name
      assert_equal 'vonderLuft', @reader.last_name
      assert_equal 'Andrew vonderLuft', @reader.display_name
    end

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

    def test_half_a_name_is_refused_and_the_form_comes_back
      @reader.update_comment_notification_level!('none')
      sign_in_as(@reader)
      patch "#{mount}/profile", params: {
        first_name: 'Andrew', last_name: '', comment_notifications: 'all'
      }

      assert_response :unprocessable_entity
      assert_equal 'R', @reader.reload.first_name, 'nothing should have changed'
      assert_equal 'none', @reader.comment_notification_level,
                   'notification preference should not change on an invalid form'
      assert_select 'input[name="comment_notifications"][value="all"][checked="checked"]'
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

    def test_bible_com_can_be_chosen
      sign_in_as(@reader)
      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', bible_version: 'LSB', passage_source: 'bible_com'
      }

      assert_equal 'bible_com', @reader.reload.passage_source
    end

    def test_an_unknown_passage_source_is_refused
      sign_in_as(@reader)
      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', bible_version: 'LSB', passage_source: 'unknown'
      }

      assert_response :unprocessable_entity
      assert_equal 'bible_com', @reader.reload.passage_source
    end

    def test_omitting_the_passage_source_returns_to_the_default
      @reader.update!(passage_source: 'blue_letter_bible')
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'R', last_name: 'Reader', bible_version: 'LSB' }

      assert_equal 'bible_com', @reader.reload.passage_source
    end

    def test_an_unknown_translation_is_refused
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'R', last_name: 'Reader', bible_version: 'NIV' }

      assert_response :unprocessable_entity
      assert_nil @reader.reload.bible_version
    end

    # Reading links should open in whatever the reader chose.
    def test_the_chosen_translation_uses_bible_com_by_default
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'R', last_name: 'Reader', bible_version: 'KJV' }
      get "#{mount}/day/1"

      assert_response :success
      assert_match(%r{\(KJV\)}, response.body)
      assert_match(%r{www\.bible\.com/bible/1/GEN\.1\.KJV}, response.body)
    end

    def test_the_bible_gateway_choice_reaches_the_day_page
      sign_in_as(@reader)
      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', bible_version: 'KJV', passage_source: 'bible_gateway'
      }
      get "#{mount}/day/1"

      assert_response :success
      assert_match(%r{biblegateway\.com.*version=KJV}, response.body)
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

    def test_the_bible_com_choice_reaches_the_day_page
      sign_in_as(@reader)
      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', bible_version: 'KJV', passage_source: 'bible_com'
      }
      get "#{mount}/day/1"

      assert_response :success
      passage_hrefs = css_select('a[data-b270-passage-link="true"]').map { |link| link['href'] }
      assert(passage_hrefs.all? { |href| href.start_with?('https://www.bible.com/bible/') })
      assert_includes passage_hrefs, 'https://www.bible.com/bible/1/GEN.1.KJV'
    end

    def test_original_languages_use_bible_com_when_selected
      sign_in_as(@reader)
      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', bible_version: 'HEB/GRK', passage_source: 'bible_com'
      }
      get "#{mount}/day/1"

      assert_response :success
      assert_match(%r{www\.bible\.com/bible/3585/GEN\.1\.WLC}, response.body)
      assert_match(%r{www\.bible\.com/bible/2270/MAT\.1\.THGNT}, response.body)
    end

    def test_all_greek_uses_lxx_and_thgnt_on_bible_com
      sign_in_as(@reader)
      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', bible_version: 'ALLGRK', passage_source: 'bible_com'
      }
      get "#{mount}/day/1"

      assert_response :success
      assert_match(%r{www\.bible\.com/bible/2503/GEN\.1\.GRCBRENT}, response.body)
      assert_match(%r{www\.bible\.com/bible/2270/MAT\.1\.THGNT}, response.body)
    end

    def test_invalid_fields_leave_the_entire_profile_and_existing_avatar_untouched
      prepare_profile_with_avatar
      invalid_fields = [
        { first_name: " \u00A0 " }, { last_name: '' }, { bible_version: 'unknown' },
        { passage_source: 'unknown' }, { display_mode: 'sepia' },
        { comment_notifications: 'unknown' }, { daily_reminder_minute: '99' },
        { daily_reminder_hour: '', daily_reminder_minute: '' }
      ]

      invalid_fields.each do |invalid|
        with_uploaded_avatar do |upload|
          assert_profile_unchanged do
            patch "#{mount}/profile", params: complete_profile_params.merge(avatar: upload).merge(invalid)
          end
        end
        assert_response :unprocessable_entity
        assert_select '.b270-flash.alert', text: %r{Please give}
      end
    end

    def test_invalid_avatar_leaves_all_settings_and_existing_avatar_untouched
      prepare_profile_with_avatar
      [{ content_type: 'image/svg+xml' }, { contents: '' },
       { contents: 'x' * (Bible270::Avatars.max_bytes + 1) }].each do |options|
        with_uploaded_avatar(**options) do |upload|
          assert_profile_unchanged do
            patch "#{mount}/profile", params: complete_profile_params.merge(avatar: upload)
          end
        end
        assert_response :unprocessable_entity
      end
    end

    def test_a_valid_profile_saves_every_setting_and_replaces_the_avatar
      prepare_profile_with_avatar
      previous_blob_id = @reader.avatar.blob.id
      with_uploaded_avatar do |upload|
        patch "#{mount}/profile", params: complete_profile_params.merge(avatar: upload)
      end

      assert_response :redirect
      assert_equal 'Your profile has been updated.', flash[:notice]
      @reader.reload
      assert_equal 'New First', @reader.first_name
      assert_equal 'von Last', @reader.last_name
      assert_equal 'New First von Last', @reader.display_name
      assert_equal 'LSB', @reader.bible_version
      assert_equal 'blue_letter_bible', @reader.passage_source
      assert_equal 'dark_green', @reader.display_mode
      assert_equal 'personal', @reader.comment_notification_level
      assert @reader.notify_on_mention
      refute @reader.notify_on_all_comments
      assert @reader.daily_reminders
      assert_equal '06:45', @reader.daily_reminder_time
      refute_equal previous_blob_id, @reader.avatar.blob.id
      assert_equal 'replacement avatar', @reader.avatar.download
    end

    def test_model_validation_failure_rerenders_without_saving_or_uploading
      prepare_profile_with_avatar
      other = Bible270::Reader.create!(provider: 'email', uid: 'other@example.org', display_name: 'Other')
      resolver = ->(_controller) { @reader }

      Bible270.config.stub(:current_reader_resolver, -> { resolver }) do
        with_uploaded_avatar do |upload|
          assert_profile_unchanged do
            # Exercise a real AR validation failure after the form checks pass.
            @reader.uid = other.uid
            patch "#{mount}/profile", params: complete_profile_params.merge(avatar: upload)
          end
        end
      end

      assert_response :unprocessable_entity
      assert_select '.b270-flash.alert', text: %r{Your profile could not be saved.*Uid has already been taken}
      assert_empty @reader.attachment_changes
      assert_select 'input[name="first_name"][value="  New   First  "]'
      assert_select 'select[name="display_mode"] option[value="dark_green"][selected]'
      assert_select 'select[name="daily_reminder_hour"] option[value="06"][selected]'
      assert_select '.b270-avatarrow img[src*="original.png"]'
    end

    def test_omitting_translation_and_avatar_preserves_them
      prepare_profile_with_avatar
      blob_id = @reader.avatar.blob.id
      patch "#{mount}/profile", params: complete_profile_params.except(:bible_version)

      assert_response :redirect
      assert_equal 'KJV', @reader.reload.bible_version
      assert_equal blob_id, @reader.avatar.blob.id
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

    def test_remove_picture_is_beside_upload_controls_and_targets_a_separate_form
      skip 'Active Storage unavailable' unless Bible270::Reader.avatar_uploads?

      @reader.avatar.attach(io: StringIO.new('x'), filename: 'a.png', content_type: 'image/png')
      sign_in_as(@reader)
      get "#{mount}/profile"

      assert_select '.b270-avatarrow .b270-avatarcontrols' do
        assert_select 'input[type="file"][name="avatar"]'
        assert_select 'button[type="submit"][form="b270-remove-picture"]', text: 'Remove picture'
      end
      assert_select 'label button', count: 0
      assert_select 'form form', count: 0
      assert_select '.b270-panel > form#b270-remove-picture[hidden][method="post"]' \
                    '[data-turbo-confirm="Remove your picture?"]' do |forms|
        assert_equal "#{mount}/profile/avatar", forms.first['action']
        assert_select 'input[name="_method"][value="delete"]'
        assert_select 'input[name="first_name"], input[name="last_name"], input[name="avatar"]', count: 0
      end
    end

    def test_remove_picture_is_hidden_without_an_uploaded_avatar
      sign_in_as(@reader)
      get "#{mount}/profile"

      assert_select 'button[form="b270-remove-picture"]', count: 0
      assert_select 'form#b270-remove-picture', count: 0
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

  private

    def complete_profile_params
      {
        first_name: '  New   First  ', last_name: " von\u00A0 Last ", bible_version: ' lsb ',
        passage_source: 'blue_letter_bible', display_mode: 'dark_green', comment_notifications: 'personal',
        daily_reminders: '1', daily_reminder_hour: '06', daily_reminder_minute: '45'
      }
    end

    def prepare_profile_with_avatar
      skip 'Active Storage unavailable' unless Bible270::Reader.avatar_uploads?

      Bible270.config.daily_reminders = true
      @reader.update!(bible_version: 'KJV', passage_source: 'bible_gateway', display_mode: 'dark_blue',
                      notify_on_mention: false, notify_on_all_comments: false,
                      daily_reminders: false, daily_reminder_time: '09:30')
      @reader.avatar.attach(io: StringIO.new('original avatar'), filename: 'original.png', content_type: 'image/png')
      sign_in_as(@reader)
    end

    def with_uploaded_avatar(content_type: 'image/png', contents: 'replacement avatar')
      file = Tempfile.new(['avatar', '.png'])
      file.binmode
      file.write(contents)
      file.rewind
      yield Rack::Test::UploadedFile.new(file.path, content_type, true, original_filename: 'replacement.png')
    ensure
      file&.close!
    end

    def assert_profile_unchanged(&block)
      attributes = @reader.reload.attributes
      attachment = @reader.avatar.attachment.attributes
      blob = @reader.avatar.blob.attributes
      storage_writes = []
      subscriber = ->(*event) { storage_writes << event.first }
      ActiveSupport::Notifications.subscribed(subscriber, %r{service_(upload|delete|delete_prefixed)\.active_storage}) do
        assert_no_difference ['ActiveStorage::Blob.count', 'ActiveStorage::Attachment.count'], &block
      end
      assert_empty storage_writes
      assert_equal attributes, @reader.reload.attributes
      assert_equal attachment, @reader.avatar.attachment.attributes
      assert_equal blob, @reader.avatar.blob.attributes
      assert_equal 'original avatar', @reader.avatar.download
    end
  end
end
