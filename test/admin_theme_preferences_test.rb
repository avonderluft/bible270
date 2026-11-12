# frozen_string_literal: true

require_relative 'support/admin_controller_test_case'

if RAILS_LOADED
  class AdminThemePreferencesTest < Bible270AdminControllerTestCase
    def test_admin_reader_rows_use_each_readers_theme_without_changing_the_page_theme
      @admin.update!(display_mode: 'dark_blue')
      sign_in_as_admin
      %w[light sage mist dark dark_green dark_blue system].each do |mode|
        @reader.update!(display_mode: mode)
        get "#{mount}/admin"

        assert_response :success
        assert_select 'body.b270[data-display-mode="dark_blue"]'
        assert_select ".b270-reader-theme[data-display-mode='#{mode}'] a[href='mailto:#{@reader.email}']"
        assert_select ".b270-reader-theme[data-display-mode='dark_blue'] a[href='mailto:#{@admin.email}']"
      end
    end

    def test_reader_row_theming_is_limited_to_the_admin_list
      @reader.update!(display_mode: 'dark_green')
      sign_in_as_admin
      get "#{mount}/community"

      assert_response :success
      assert_select '.b270-reader-theme', count: 0
      assert_select '.b270-li[data-display-mode]', count: 0
    end

    def test_reader_theme_selector_has_the_profile_options_and_saved_selection
      @reader.update!(display_mode: 'dark_green')
      sign_in_as_admin
      get "#{mount}/admin/readers/#{@reader.id}"

      assert_select "form[action='#{mount}/admin/readers/#{@reader.id}/theme']" do
        assert_select 'input[name="_method"][value="patch"]'
        assert_select 'select[name="display_mode"][aria-labelledby="b270-theme-heading"][aria-describedby="b270-theme-hint b270-theme-status"]' do
          assert_select 'option', count: 7 do |options|
            choices = options.map { |option| [option.text, option['value']] }
            assert_equal [
              ['Papyrus (Light)', 'light'],
              ['Meadow (Light)', 'sage'],
              ['Ocean (Light)', 'mist'],
              ['Cedar (Dark)', 'dark'],
              ['Forest (Dark)', 'dark_green'],
              ['Moonlight (Dark)', 'dark_blue'],
              ['System', 'system']
            ], choices
          end
          assert_select 'option[value="dark_green"][selected]', text: 'Forest (Dark)'
        end
        assert_select 'input[type="submit"][value="Save"][data-b270-theme-fallback="true"]'
        assert_select "select[data-b270-theme-url='#{mount}/admin/readers/#{@reader.id}/theme'][data-b270-theme-apply='false']"
        assert_select '#b270-theme-status[role="status"]'
        assert_select '#b270-theme-hint.b270-theme-hint', text: 'System: Papyrus (light), Cedar (dark).'
      end
      assert_select 'body[data-display-mode="system"]'
    end

    def test_admin_can_save_each_theme_without_changing_other_settings_or_their_own_theme
      sign_in_as_admin
      original = @reader.attributes.except('display_mode', 'updated_at')
      %w[light sage mist dark dark_green dark_blue system].each do |mode|
        patch "#{mount}/admin/readers/#{@reader.id}/theme", params: { display_mode: mode, first_name: 'Ignored' }
        assert_redirected_to "#{mount}/admin/readers/#{@reader.id}"
        assert_equal mode, @reader.reload.display_mode
        assert_equal original, @reader.attributes.except('display_mode', 'updated_at')
        assert_equal 'system', @admin.reload.display_mode
        follow_redirect!
        assert_select "select[name='display_mode'] option[value='#{mode}'][selected]"
      end
    end

    def test_invalid_and_missing_admin_theme_choices_leave_the_preference_unchanged
      @reader.update!(display_mode: 'dark_blue')
      sign_in_as_admin
      ['sepia', '', nil].each do |mode|
        patch "#{mount}/admin/readers/#{@reader.id}/theme", params: { display_mode: mode }
        assert_redirected_to "#{mount}/admin/readers/#{@reader.id}"
        assert_equal 'dark_blue', @reader.reload.display_mode
        assert_equal 'Choose a theme from the list.', flash[:alert]
      end
    end

    def test_admin_theme_settings_explain_a_pending_migration
      sign_in_as_admin
      Bible270::Reader.stub(:display_mode_column?, false) do
        get "#{mount}/admin/readers/#{@reader.id}"
        assert_response :success
        assert_select 'select[name="display_mode"]', count: 0
        assert_select '.b270-flash.alert', text: %r{pending Bible270 database migration before changing the theme}
        patch "#{mount}/admin/readers/#{@reader.id}/theme", params: { display_mode: 'dark' }
        assert_redirected_to "#{mount}/admin/readers/#{@reader.id}"
        assert_match(%r{pending Bible270 database migration}, flash[:alert])
      end
      assert_equal 'system', @reader.reload.display_mode
    end

    def test_visitors_and_ordinary_readers_cannot_use_the_admin_theme_action
      patch "#{mount}/admin/readers/#{@reader.id}/theme", params: { display_mode: 'dark' }
      assert_response :not_found
      sign_in_as(@reader)
      patch "#{mount}/admin/readers/#{@reader.id}/theme", params: { display_mode: 'dark' }
      assert_response :not_found
      assert_equal 'system', @reader.reload.display_mode
    end

    def test_admin_theme_action_handles_a_missing_reader
      sign_in_as_admin
      patch "#{mount}/admin/readers/999999/theme", params: { display_mode: 'dark' }
      assert_redirected_to "#{mount}/admin"
      assert_equal 'Reader not found.', flash[:alert]
    end

    def test_admin_theme_autosave_saves_every_mode_as_json_without_changing_other_settings_or_admin
      @admin.update!(display_mode: 'dark_blue')
      sign_in_as_admin
      original = @reader.attributes.except('display_mode', 'updated_at')
      admin_original = @admin.reload.attributes

      Bible270::Reader::DISPLAY_MODES.each do |mode|
        patch "#{mount}/admin/readers/#{@reader.id}/theme", as: :json, params: {
          display_mode: mode, reader_id: @admin.id,
          first_name: 'Changed', last_name: '', email: 'attacker@example.org',
          bible_version: 'KJV', passage_source: 'bible_gateway', avatar: 'ignored',
          comment_notifications: 'none', notify_on_mention: false, notify_on_all_comments: false,
          daily_reminders: '1', daily_reminder_time: '12:00', completion_dove_disabled: '1',
          reader: { display_mode: 'sepia', first_name: 'Nested' }
        }

        assert_response :success
        assert_equal 'application/json', response.media_type
        assert_equal({ 'display_mode' => mode }, response.parsed_body)
        assert_equal mode, @reader.reload.display_mode
        assert_equal original, @reader.attributes.except('display_mode', 'updated_at')
        assert_equal admin_original, @admin.reload.attributes
      end
    end

    def test_admin_theme_autosave_rejects_invalid_blank_null_and_missing_modes_as_json
      @reader.update!(display_mode: 'dark_blue')
      sign_in_as_admin
      original = @reader.attributes
      [{ display_mode: 'sepia' }, { display_mode: '' }, { display_mode: nil }, {}].each do |parameters|
        patch "#{mount}/admin/readers/#{@reader.id}/theme", params: parameters, as: :json

        assert_response :unprocessable_entity
        assert_equal({ 'error' => 'Choose a theme from the list.' }, response.parsed_body)
        assert_equal original, @reader.reload.attributes
      end
    end

    def test_admin_theme_autosave_reports_a_pending_migration_as_json
      sign_in_as_admin
      original = @reader.attributes
      Bible270::Reader.stub(:display_mode_column?, false) do
        patch "#{mount}/admin/readers/#{@reader.id}/theme", params: { display_mode: 'dark' }, as: :json
      end

      assert_response :unprocessable_entity
      assert_equal ['error'], response.parsed_body.keys
      assert_match(%r{pending Bible270 database migration}, response.parsed_body['error'])
      assert_equal original, @reader.reload.attributes
    end

    def test_admin_theme_autosave_is_hidden_from_visitors_ordinary_readers_and_unconfigured_admins
      Bible270.config.admin_emails = [@admin.email]
      patch "#{mount}/admin/readers/#{@reader.id}/theme", params: { display_mode: 'dark' }, as: :json
      assert_response :not_found

      sign_in_as(@reader)
      patch "#{mount}/admin/readers/#{@reader.id}/theme", params: { display_mode: 'dark' }, as: :json
      assert_response :not_found

      sign_in_as_admin
      Bible270.config.admin_emails = []
      patch "#{mount}/admin/readers/#{@reader.id}/theme", params: { display_mode: 'dark' }, as: :json
      assert_response :not_found
      assert_equal 'system', @reader.reload.display_mode
    end

    def test_admin_theme_autosave_honors_the_custom_admin_resolver
      sign_in_as(@admin)
      Bible270.config.admin_emails = []
      Bible270.config.admin_resolver = ->(reader) { reader&.id == @admin.id }
      patch "#{mount}/admin/readers/#{@reader.id}/theme", params: { display_mode: 'mist' }, as: :json

      assert_response :success
      assert_equal({ 'display_mode' => 'mist' }, response.parsed_body)
      assert_equal 'mist', @reader.reload.display_mode
      assert_equal 'system', @admin.reload.display_mode
    end

    def test_admin_theme_autosave_reports_a_missing_reader_as_json
      sign_in_as_admin
      patch "#{mount}/admin/readers/999999/theme", params: { display_mode: 'dark' }, as: :json

      assert_response :unprocessable_entity
      assert_equal({ 'error' => 'Reader not found.' }, response.parsed_body)
      assert_equal 'system', @admin.reload.display_mode
    end

    def test_admin_theme_autosave_reloads_a_reader_missing_the_display_attribute
      sign_in_as_admin
      columns = Bible270::Reader.column_names - ['display_mode']
      partial_reader = Bible270::Reader.select(*columns).find(@reader.id)
      refute partial_reader.has_attribute?(:display_mode)
      resolver = ->(_controller) { @admin }
      Bible270.config.stub(:current_reader_resolver, -> { resolver }) do
        Bible270::Reader.stub(:find_by, partial_reader) do
          patch "#{mount}/admin/readers/#{@reader.id}/theme", params: { display_mode: 'sage' }, as: :json
        end
      end

      assert_response :success
      assert_equal({ 'display_mode' => 'sage' }, response.parsed_body)
      assert_equal 'sage', @reader.reload.display_mode
      assert_equal 'system', @admin.reload.display_mode
    end

    def test_admin_theme_autosave_returns_json_for_persistence_validation_errors
      sign_in_as_admin
      @reader.update_column(:display_name, '')
      original = @reader.attributes
      patch "#{mount}/admin/readers/#{@reader.id}/theme", params: { display_mode: 'dark' }, as: :json

      assert_response :unprocessable_entity
      assert_equal ['error'], response.parsed_body.keys
      assert_match(%r{Display name can't be blank}, response.parsed_body['error'])
      assert_equal original, @reader.reload.attributes

      patch "#{mount}/admin/readers/#{@reader.id}/theme", params: { display_mode: 'dark' }
      assert_redirected_to "#{mount}/admin/readers/#{@reader.id}"
      assert_match(%r{Display name can't be blank}, flash[:alert])
      assert_equal original, @reader.reload.attributes
    end

    def test_admin_theme_autosave_returns_json_when_persistence_is_aborted
      sign_in_as_admin
      resolver = ->(_controller) { @admin }
      failure = ->(*) { raise ActiveRecord::RecordNotSaved, 'Save aborted' }
      Bible270.config.stub(:current_reader_resolver, -> { resolver }) do
        Bible270::Reader.stub(:find_by, @reader) do
          @reader.stub(:update!, failure) do
            patch "#{mount}/admin/readers/#{@reader.id}/theme", params: { display_mode: 'dark' }, as: :json
          end
        end
      end

      assert_response :unprocessable_entity
      assert_equal({ 'error' => 'The theme could not be saved. Please try again.' }, response.parsed_body)
      assert_equal 'system', @reader.reload.display_mode
    end

    def test_an_admin_sees_a_readers_reflection_email_setting
      sign_in_as_admin

      get "#{mount}/admin/readers/#{@reader.id}"

      assert_select 'h2', text: 'Email notifications'
      assert_select 'input[type="radio"][name="comment_notifications"]', count: 3
      assert_select 'input[name="comment_notifications"][value="all"][checked="checked"]'
    end

    def test_an_admin_can_change_a_readers_reflection_email_setting
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/notifications",
            params: { comment_notifications: 'all' }

      assert_response :redirect
      assert_equal 'all', @reader.reload.comment_notification_level
    end

    def test_admin_reflection_email_controls_explain_a_pending_migration
      sign_in_as_admin

      Bible270::Reader.stub(:comment_notification_columns?, false) do
        get "#{mount}/admin/readers/#{@reader.id}"
        assert_select 'input[name="comment_notifications"]', count: 0
        assert_select '.b270-flash.alert', text: %r{pending Bible270 database migration}i

        patch "#{mount}/admin/readers/#{@reader.id}/notifications",
              params: { comment_notifications: 'personal' }
        assert_equal 'all', @reader.reload.comment_notification_level
        assert_match(%r{pending Bible270 database migration}i, flash[:alert])
      end
    end

    def test_admin_reflection_email_controls_respect_the_global_switch
      @reader.update_comment_notification_level!('all')
      Bible270.config.mention_notifications = false
      sign_in_as_admin

      get "#{mount}/admin/readers/#{@reader.id}"
      assert_select 'input[name="comment_notifications"]', count: 0
      assert_select '.b270-hint', text: %r{Reflection emails are disabled}i

      patch "#{mount}/admin/readers/#{@reader.id}/notifications",
            params: { comment_notifications: 'none' }
      assert_equal 'all', @reader.reload.comment_notification_level
    end

    def test_an_invalid_reflection_email_setting_is_refused_without_changing_it
      @reader.update_comment_notification_level!('all')
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/notifications",
            params: { comment_notifications: 'sometimes' }

      assert_response :redirect
      assert_equal 'all', @reader.reload.comment_notification_level
      assert_match(%r{from the list}, flash[:alert].to_s)
    end

    def test_an_admin_sees_one_explicit_completion_animation_button_for_each_state
      sign_in_as_admin

      [[false, 'Disable', '1'], [true, 'Enable', '0']].each do |disabled, label, value|
        @reader.update!(completion_dove_disabled: disabled)
        get "#{mount}/admin/readers/#{@reader.id}"
        assert_response :success

        assert_select '#b270-completion-animation.b270-admin-control', count: 1 do
          assert_select '> h2#b270-completion-animation-heading', text: 'Completion animation'
          assert_select "> form.b270-admin-inline-form[aria-labelledby='b270-completion-animation-heading'][action='#{mount}/admin/readers/#{@reader.id}/completion-animation'][method='post']", count: 1 do
            assert_select 'input[type="hidden"][name="_method"][value="patch"]', count: 1
            assert_select 'input[name="completion_dove_disabled"]', count: 1
            assert_select "input[type='hidden'][name='completion_dove_disabled'][value='#{value}']", count: 1
            assert_select 'input[type="submit"], button', count: 1
            assert_select "input[type='submit'].b270-btn[value='#{label}']", count: 1
          end
          assert_select 'input[type="checkbox"], input[type="submit"][value="Save"], label, p', count: 0
        end
      end
    end

    def test_an_admin_can_turn_a_readers_completion_animation_off_and_back_on
      sign_in_as_admin

      %w[1 1 0 0].each do |value|
        patch "#{mount}/admin/readers/#{@reader.id}/completion-animation",
              params: { completion_dove_disabled: value }
        assert_redirected_to "#{mount}/admin/readers/#{@reader.id}"
        assert_equal value == '1', @reader.reload.completion_dove_disabled?
      end
    end

    def test_omitting_the_completion_animation_preference_still_enables_it
      @reader.update!(completion_dove_disabled: true)
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/completion-animation"
      assert_response :redirect
      refute @reader.reload.completion_dove_disabled?
    end

    def test_admin_completion_animation_control_explains_a_pending_migration
      sign_in_as_admin

      Bible270::Reader.stub(:completion_dove_column?, false) do
        get "#{mount}/admin/readers/#{@reader.id}"
        assert_select '#b270-completion-animation' do
          assert_select 'h2', text: 'Completion animation'
          assert_select 'form, input, button', count: 0
          assert_select '.b270-flash.alert', text: %r{pending Bible270 database migration before changing the completion animation}i
        end

        patch "#{mount}/admin/readers/#{@reader.id}/completion-animation",
              params: { completion_dove_disabled: '1' }
        refute @reader.reload.completion_dove_disabled?
        assert_match(%r{pending Bible270 database migration}i, flash[:alert])
      end
    end

    def test_plan_position_controls_share_a_row_but_keep_their_forms_separate
      @reader.update!(started_on: Bible270.today - 4)
      sign_in_as_admin
      get "#{mount}/admin/readers/#{@reader.id}"
      assert_response :success

      assert_select '.b270-admin-position-controls', count: 1 do
        assert_select '> form.b270-startform', count: 2 do |forms|
          forms.each do |form|
            assert_equal "#{mount}/admin/readers/#{@reader.id}/start", form['action']
            assert_equal 'post', form['method']
            assert_select form, 'input[type="hidden"][name="_method"][value="patch"]', count: 1
            assert_select form, "input[type='hidden'][name='participation_id'][value='#{@reader.participation.id}']", count: 1
            assert_select form, 'input[type="submit"].b270-btn', count: 1
            assert_select form, 'form', count: 0
          end

          assert_select forms.first, 'label.b270-field > span', text: 'Day:'
          assert_select forms.first, "input[type='number'][name='day'][value='5'][min='1'][max='#{Bible270::Plan::DAYS}']", count: 1
          assert_select forms.first, 'input[type="submit"][value="Move"]', count: 1
          assert_select forms.first, 'input[name="start_date"]', count: 0

          assert_select forms.last, 'label.b270-field > span', text: 'Start date:'
          assert_select forms.last, "input[type='date'][name='start_date'][value='#{@reader.started_on.iso8601}']", count: 1
          assert_select forms.last, 'input[type="submit"][value="Set date"]', count: 1
          assert_select forms.last, 'input[name="day"]', count: 0
        end
      end
      assert_select '.b270-admin-position-controls + .b270-hint',
                    text: 'Moving someone re-maps the calendar only. Their check-offs are keyed to day numbers and are not touched.'
    end

    def test_alumni_have_no_plan_position_controls
      @reader.archive!
      sign_in_as_admin
      get "#{mount}/admin/readers/#{@reader.id}"
      assert_response :success

      assert_select '.b270-admin-position-controls', count: 0
      assert_select "form[action='#{mount}/admin/readers/#{@reader.id}/start']", count: 0
    end

    # ---- which translation a reader gets ------------------------------------

    def test_the_page_shows_a_readers_translation
      @reader.update_bible_version('KJV')
      sign_in_as_admin

      get "#{mount}/admin/readers/#{@reader.id}"

      assert_response :success
      assert_match(%r{Which translation they read}, response.body)
      assert_match(%r{<option selected="selected" value="KJV">}, response.body)
      assert_match(%r{name="bible_version".*class="b270-source-choices"}m, response.body,
                   'reader choice belongs immediately below the translation selector')
      assert_equal 3, response.body.scan(%r{name="passage_source"}).size
      assert_match(%r{value="bible_com" checked="checked"}, response.body)
    end

    def test_it_says_when_a_reader_has_no_preference
      sign_in_as_admin

      get "#{mount}/admin/readers/#{@reader.id}"

      assert_match(%r{no preference}, response.body)
      assert_match(%r{Site default}, response.body)
    end

    def test_an_admin_can_set_a_readers_translation
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/version", params: { bible_version: 'LSB' }

      assert_equal 'LSB', @reader.reload.bible_version
      assert_equal 'LSB', @reader.effective_bible_version
    end

    def test_an_admin_can_choose_bible_gateway_for_a_reader
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/version",
            params: { bible_version: 'LSB', passage_source: 'bible_gateway' }

      assert_equal 'bible_gateway', @reader.reload.passage_source
    end

    def test_an_admin_can_choose_blue_letter_bible_for_a_reader
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/version",
            params: { bible_version: 'LSB', passage_source: 'blue_letter_bible' }

      assert_equal 'blue_letter_bible', @reader.reload.passage_source
    end

    def test_an_admin_can_choose_bible_com_for_a_reader
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/version",
            params: { bible_version: 'LSB', passage_source: 'bible_com' }

      assert_equal 'bible_com', @reader.reload.passage_source
    end

    def test_an_admin_can_set_all_greek_with_bible_com
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/version",
            params: { bible_version: 'ALLGRK', passage_source: 'bible_com' }

      @reader.reload
      assert_equal 'ALLGRK', @reader.bible_version
      assert_equal 'bible_com', @reader.passage_source
    end

    def test_an_admin_cannot_set_an_unknown_passage_source
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/version",
            params: { bible_version: 'LSB', passage_source: 'unknown' }

      assert_equal 'bible_com', @reader.reload.passage_source
      assert_match(%r{not a reading-link source}, flash[:alert].to_s)
    end

    def test_omitting_the_source_returns_a_reader_to_bible_com
      @reader.update!(passage_source: 'blue_letter_bible')
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/version", params: { bible_version: 'LSB' }

      assert_equal 'bible_com', @reader.reload.passage_source
    end

    # Blank is not the same as picking today's default: it means follow whatever
    # the site uses, including after the site changes it.
    def test_clearing_it_returns_them_to_the_site_default
      @reader.update_bible_version('KJV')
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/version", params: { bible_version: '' }

      assert_nil @reader.reload.bible_version
      assert_equal Bible270.config.bible_version, @reader.effective_bible_version
    end

    def test_an_unknown_translation_is_refused
      @reader.update_bible_version('KJV')
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/version", params: { bible_version: 'NIV' }

      assert_equal 'KJV', @reader.reload.bible_version, 'unchanged'
      assert_match(%r{not a translation}, flash[:alert].to_s)
    end

    def test_update_bible_version_handles_its_separate_stale_reader_lookup
      sign_in_as_admin

      patch "#{mount}/admin/readers/999999/version", params: { bible_version: 'KJV' }

      assert_redirected_to "#{mount}/admin"
      assert_match(%r{No such reader}, flash[:alert].to_s)
      assert_nil @reader.reload.bible_version
    end

    def test_an_ordinary_reader_cannot_set_someone_elses_translation
      sign_in_as(@reader)

      patch "#{mount}/admin/readers/#{@admin.id}/version", params: { bible_version: 'KJV' }

      assert_response :not_found
      assert_nil @admin.reload.bible_version
    end

    def test_a_visitor_cannot_set_a_readers_translation
      patch "#{mount}/admin/readers/#{@reader.id}/version", params: { bible_version: 'KJV' }

      assert_response :not_found
      assert_nil @reader.reload.bible_version
    end

    # The point of the setting: reading links open in their translation.
    def test_the_choice_uses_bible_com_on_the_readers_day_page
      sign_in_as_admin
      patch "#{mount}/admin/readers/#{@reader.id}/version", params: { bible_version: 'KJV' }
      reset!

      _record, raw = Bible270::SignInToken.issue!(@reader.email)
      get "#{mount}/sign_in/email/#{raw}"
      get "#{mount}/day/1"

      assert_match(%r{www\.bible\.com/bible/1/GEN\.1\.KJV}, response.body)
    end

    def test_the_blue_letter_bible_choice_reaches_the_readers_day_page
      sign_in_as_admin
      patch "#{mount}/admin/readers/#{@reader.id}/version",
            params: { bible_version: 'KJV', passage_source: 'blue_letter_bible' }
      reset!

      _record, raw = Bible270::SignInToken.issue!(@reader.email)
      get "#{mount}/sign_in/email/#{raw}"
      get "#{mount}/day/1"

      assert_match(%r{blueletterbible\.org/kjv/gen/1/1/s_1001}, response.body)
    end

    def test_the_bible_com_choice_reaches_the_readers_day_page
      sign_in_as_admin
      patch "#{mount}/admin/readers/#{@reader.id}/version",
            params: { bible_version: 'KJV', passage_source: 'bible_com' }
      reset!

      _record, raw = Bible270::SignInToken.issue!(@reader.email)
      get "#{mount}/sign_in/email/#{raw}"
      get "#{mount}/day/1"

      assert_match(%r{www\.bible\.com/bible/1/GEN\.1\.KJV}, response.body)
    end
  end
end
