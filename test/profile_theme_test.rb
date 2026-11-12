# frozen_string_literal: true

require_relative 'support/profiles_controller_test_case'

if RAILS_LOADED
  class ProfileThemeTest < Bible270ProfilesControllerTestCase
    def test_display_defaults_to_system_for_readers_and_visitors
      get "#{mount}/sign_in"
      assert_select 'body[data-display-mode="system"]'
      assert_select '#b270-header-theme', count: 0

      sign_in_as(@reader)
      get "#{mount}/profile"
      assert_select 'body[data-display-mode="system"]'
      assert_select 'label.b270-field > span', text: 'Theme'
      assert_select "select[data-b270-theme-url='#{mount}/profile/theme'][data-b270-theme-apply='true']"
      assert_select '#b270-theme-status[role="status"]'
      assert_select '#b270-display-hint', text: "System follows your device's setting: Papyrus for light, Cedar for dark."
      assert_select 'select#display_mode' do
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
        assert_select 'option[value="system"][selected]', text: 'System'
      end
    end

    def test_compact_header_theme_selector_is_present_on_signed_in_pages
      @reader.update!(display_mode: 'dark_blue')
      sign_in_as(@reader)

      %w[/progress /day/1 /profile].each do |path|
        get "#{mount}#{path}"
        assert_response :success
        assert_select ".b270-brand > form.b270-header-theme[action='#{mount}/profile/theme'][method='post']", count: 1 do
          assert_select 'input[name="_method"][value="patch"]'
          assert_select '#b270-header-theme[aria-label="Theme"][aria-describedby="b270-header-theme-status"]' do
            assert_select 'option', count: 7 do |options|
              assert_equal %w[Papyrus Meadow Ocean Cedar Forest Moonlight System], options.map(&:text)
              assert_equal(Bible270::Reader::DISPLAY_MODES, options.map { |option| option['value'] })
            end
            assert_select 'option[value="dark_blue"][selected]', text: 'Moonlight'
          end
          assert_select "select[data-b270-theme-url='#{mount}/profile/theme'][data-b270-theme-apply='true'][data-b270-saved-theme='dark_blue']"
          assert_select 'select[data-b270-theme-status="b270-header-theme-status"]'
          assert_select '#b270-header-theme-status[role="status"][aria-live="polite"]'
          assert_select 'input[type="submit"][data-b270-theme-fallback="true"]'
        end
        assert_equal 1, response.body.scan('window.Bible270ThemeUI =').size
        assert_select '#b270-header-theme', count: 1
        assert_select '#b270-header-theme-status', count: 1
      end
    end

    def test_each_display_preference_is_saved_and_applied_on_other_pages
      sign_in_as(@reader)
      schemes = { 'light' => 'only light', 'sage' => 'only light', 'mist' => 'only light',
                  'dark' => 'dark', 'dark_green' => 'dark', 'dark_blue' => 'dark', 'system' => 'light dark' }
      schemes.each do |mode, scheme|
        patch "#{mount}/profile", params: { first_name: 'R', last_name: 'Reader', display_mode: mode }
        assert_response :redirect
        assert_equal mode, @reader.reload.display_mode

        follow_redirect!
        assert_select "body[data-display-mode='#{mode}']"
        assert_select "select[name='display_mode'] option[value='#{mode}'][selected]"
        get "#{mount}/progress"
        assert_select "body[data-display-mode='#{mode}']"
        assert_select "html[data-b270-display-mode='#{mode}']"
        assert_select "head meta#b270-color-scheme[name='color-scheme'][content='#{scheme}']", count: 1
        assert_operator response.body.index('name="color-scheme"'), :<, response.body.index('<style>')
      end
    end

    def test_existing_dark_preference_is_shown_as_cedar
      @reader.update!(display_mode: 'dark')
      sign_in_as(@reader)
      get "#{mount}/profile"

      assert_select 'body[data-display-mode="dark"]'
      assert_select 'select#display_mode option[value="dark"][selected]', text: 'Cedar (Dark)'
      assert_select '#b270-header-theme option[value="dark"][selected]', text: 'Cedar'
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

    def test_theme_autosave_route_is_named
      assert_equal "#{mount}/profile/theme", Bible270::Engine.routes.url_helpers.profile_theme_path
    end

    def test_theme_autosave_saves_every_mode_as_json_and_ignores_other_fields
      sign_in_as(@reader)
      other = Bible270::Reader.create!(provider: 'email', uid: 'other@example.org', display_name: 'Other')
      original = @reader.reload.attributes.except('display_mode', 'updated_at')
      other_original = other.attributes

      Bible270::Reader::DISPLAY_MODES.each do |mode|
        patch "#{mount}/profile/theme", as: :json, params: {
          display_mode: mode, id: other.id, reader_id: other.id,
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
        assert_equal other_original, other.reload.attributes
      end
    end

    def test_theme_autosave_rejects_invalid_blank_null_and_missing_modes_as_json
      @reader.update!(display_mode: 'dark_blue')
      sign_in_as(@reader)
      original = @reader.reload.attributes
      [{ display_mode: 'sepia' }, { display_mode: '' }, { display_mode: nil }, {}].each do |parameters|
        patch "#{mount}/profile/theme", params: parameters, as: :json

        assert_response :unprocessable_entity
        assert_equal({ 'error' => 'Choose a theme from the list.' }, response.parsed_body)
        assert_equal original, @reader.reload.attributes
      end
    end

    def test_theme_autosave_reports_a_pending_migration_as_json
      sign_in_as(@reader)
      original = @reader.reload.attributes
      Bible270::Reader.stub(:display_mode_column?, false) do
        patch "#{mount}/profile/theme", params: { display_mode: 'dark' }, as: :json
      end

      assert_response :unprocessable_entity
      assert_equal ['error'], response.parsed_body.keys
      assert_match(%r{pending Bible270 database migration}, response.parsed_body['error'])
      assert_equal original, @reader.reload.attributes
    end

    def test_theme_autosave_requires_a_signed_in_reader
      original = @reader.attributes
      patch "#{mount}/profile/theme", params: { display_mode: 'dark', id: @reader.id }, as: :json

      assert_response :unprocessable_entity
      assert_equal({ 'error' => 'Please sign in first.' }, response.parsed_body)
      assert_equal original, @reader.reload.attributes

      patch "#{mount}/profile/theme", params: { display_mode: 'dark' }
      assert_response :redirect
      assert_match(%r{sign_in}, response.location)
      assert_equal original, @reader.reload.attributes
    end

    def test_theme_autosave_reloads_a_reader_missing_the_display_attribute
      columns = Bible270::Reader.column_names - ['display_mode']
      partial_reader = Bible270::Reader.select(*columns).find(@reader.id)
      refute partial_reader.has_attribute?(:display_mode)
      resolver = ->(_controller) { partial_reader }
      Bible270.config.stub(:current_reader_resolver, -> { resolver }) do
        patch "#{mount}/profile/theme", params: { display_mode: 'sage' }, as: :json
      end

      assert_response :success
      assert_equal({ 'display_mode' => 'sage' }, response.parsed_body)
      assert_equal 'sage', @reader.reload.display_mode
    end

    def test_theme_autosave_returns_json_for_persistence_validation_errors
      sign_in_as(@reader)
      @reader.update_column(:display_name, '')
      original = @reader.reload.attributes
      patch "#{mount}/profile/theme", params: { display_mode: 'dark' }, as: :json

      assert_response :unprocessable_entity
      assert_equal ['error'], response.parsed_body.keys
      assert_match(%r{Display name can't be blank}, response.parsed_body['error'])
      assert_equal original, @reader.reload.attributes
    end

    def test_theme_autosave_returns_json_when_persistence_is_aborted
      resolver = ->(_controller) { @reader }
      failure = ->(*) { raise ActiveRecord::RecordNotSaved, 'Save aborted' }
      Bible270.config.stub(:current_reader_resolver, -> { resolver }) do
        @reader.stub(:update!, failure) do
          patch "#{mount}/profile/theme", params: { display_mode: 'dark' }, as: :json
        end
      end

      assert_response :unprocessable_entity
      assert_equal({ 'error' => 'Your theme could not be saved. Please try again.' }, response.parsed_body)
      assert_equal 'system', @reader.reload.display_mode
    end

    def test_theme_autosave_supports_html_redirects
      sign_in_as(@reader)
      patch "#{mount}/profile/theme", params: { display_mode: 'dark' }
      assert_redirected_to "#{mount}/profile"
      assert_equal 'Theme updated.', flash[:notice]
      assert_equal 'dark', @reader.reload.display_mode

      patch "#{mount}/profile/theme", params: { display_mode: 'sepia' }
      assert_redirected_to "#{mount}/profile"
      assert_equal 'Choose a theme from the list.', flash[:alert]
      assert_equal 'dark', @reader.reload.display_mode
    end
  end
end
