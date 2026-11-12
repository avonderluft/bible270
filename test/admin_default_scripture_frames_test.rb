# frozen_string_literal: true

require 'test_helper'
require 'bible270/scripture_frames'

if RAILS_LOADED
  class AdminDefaultScriptureFramesTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_config = %i[
        admin_emails admin_resolver current_reader_resolver registration_notice_deliver_later
        scripture_frames_path start_date allow_reader_start_date
      ].to_h { |key| [key, Bible270.config.public_send(key)] }
      Bible270.config.admin_resolver = nil
      Bible270.config.current_reader_resolver = nil
      Bible270.config.registration_notice_deliver_later = false
      Bible270.config.scripture_frames_path = nil
      Bible270.config.start_date = Bible270.today - 9
      Bible270.config.allow_reader_start_date = true
      @admin = create_reader('admin', admin: true)
      @site_admin = create_reader('site-admin')
      @reader = create_reader('reader')
      Bible270.config.admin_emails = [@site_admin.email]
      @defaults = Bible270::ScriptureFrames.defaults
      @frame = @defaults.first
      @custom = Bible270::ScriptureFrame.create!(
        reference: @frame.reference, translation: @frame.translation, text: 'Independent custom text.', enabled: false
      )
      @directory = Dir.mktmpdir('admin-default-scripture-frames')
    end

    def teardown
      @previous_config&.each { |key, value| Bible270.config.public_send("#{key}=", value) }
      FileUtils.rm_rf(@directory) if @directory
    end

    def test_ordinary_admin_can_explicitly_disable_and_enable_a_default
      assert_toggles_available(@admin)
    end

    def test_site_admin_can_explicitly_disable_and_enable_a_default
      assert_toggles_available(@site_admin)
    end

    def test_alumni_ordinary_admin_can_toggle_without_reactivation
      @admin.archive!
      before = @admin.participation.attributes

      assert_toggles_available(@admin)

      assert @admin.reload.alumni?
      assert_equal before, @admin.participation.reload.attributes
    end

    def test_alumni_site_admin_can_toggle_without_reactivation
      @site_admin.archive!
      before = @site_admin.participation.attributes

      assert_toggles_available(@site_admin)

      assert @site_admin.reload.alumni?
      assert_equal before, @site_admin.participation.reload.attributes
    end

    def test_visitors_cannot_toggle_defaults
      assert_toggles_hidden
    end

    def test_readers_cannot_toggle_defaults
      sign_in_as(@reader)
      assert_toggles_hidden
    end

    def test_alumni_readers_cannot_toggle_defaults
      @reader.archive!
      sign_in_as(@reader)
      before = @reader.participation.attributes

      assert_toggles_hidden

      assert @reader.reload.alumni?
      assert_equal before, @reader.participation.reload.attributes
    end

    def test_reader_preview_denies_toggles_for_both_admin_roles_until_admin_view_is_restored
      [@admin, @site_admin].each do |admin|
        sign_in_as(admin)
        patch "#{admin_path}/view", params: { view: 'reader' }
        assert_response :see_other
        get admin_path
        assert_response :success
        assert_select '.b270-scripture-default-toggle', count: 0

        assert_toggles_hidden

        patch "#{admin_path}/view", params: { view: 'admin' }
        assert_response :see_other
        patch default_path, params: { enabled: '0' }
        assert_response :see_other
        assert_redirected_to library_path
        assert_includes Bible270::ScriptureFrames.disabled_default_ids, @frame.id
        patch default_path, params: { enabled: '1' }
        assert_response :see_other
        assert_redirected_to library_path
      end
    end

    def test_route_helper_and_patch_preserve_the_full_default_id
      helper = Bible270::Engine.routes.url_helpers
      assert_equal default_path, helper.admin_default_scripture_frame_path(@frame.id)
      sign_in_as(@admin)

      patch default_path, params: { enabled: '0' }

      assert_response :see_other
      assert_equal @frame.id, request.path_parameters[:id]
      assert_equal 'update_default', request.path_parameters[:action]
      assert_redirected_to library_path
    end

    def test_missing_array_hash_and_invalid_enabled_values_are_rejected_without_changes
      sign_in_as(@admin)
      [true, false].each do |initially_enabled|
        Bible270::ScriptureFrames.set_default_enabled!(@frame.id, enabled: initially_enabled)
        invalid_values = [nil, '', 'true', 'false', 'yes', '2', '00', ' 0 ', ['0'], ['1'], { value: '0' }]
        parameters = [{}, { scripture_frame: { enabled: '0' } }] + invalid_values.map { |value| { enabled: value } }
        before = settings_snapshot

        parameters.each do |params|
          patch default_path, params: params

          assert_response :see_other
          assert_redirected_to library_path
          assert flash[:alert].present?, "Expected an alert for #{params.inspect}"
          assert_equal before, settings_snapshot, "Invalid enabled parameter changed settings: #{params.inspect}"
        end
      end
    end

    def test_json_booleans_and_numbers_are_not_accepted_as_explicit_string_states
      sign_in_as(@admin)
      before = settings_snapshot
      [true, false, 0, 1].each do |enabled|
        patch default_path, params: { enabled: enabled }, as: :json

        assert_response :see_other
        assert_redirected_to library_path
        assert flash[:alert].present?
        assert_equal before, settings_snapshot
      end
    end

    def test_unknown_malformed_custom_and_unprefixed_ids_return_404_without_changes
      sign_in_as(@admin)
      before = settings_snapshot
      ids = ['default:not-in-the-current-catalog', @frame.id.delete_prefix('default:'),
             'default:', 'default:UPPERCASE', 'default:bad_slug', 'default:two--hyphens',
             'default:psalm-119-130:extra', "custom:#{@custom.id}", @custom.id.to_s]

      ids.each do |id|
        patch default_path(id), params: { enabled: '0' }

        assert_response :not_found
        assert_equal before, settings_snapshot
      end
    end

    def test_only_current_host_catalog_ids_can_be_toggled_and_yaml_is_unchanged
      sign_in_as(@admin)
      bundled_path = Bible270::Engine.root.join('config/scripture_frames.yml')
      bundled_yaml = File.binread(bundled_path)
      host_path = File.join(@directory, 'frames.yml')
      host_yaml = YAML.dump([{ 'id' => 'host-only', 'reference' => 'Host passage', 'translation' => 'KJV',
                               'text' => 'A host supplied passage.', 'attribution' => nil }])
      File.write(host_path, host_yaml)
      Bible270.config.scripture_frames_path = host_path
      before = settings_snapshot

      patch default_path, params: { enabled: '0' }
      assert_response :not_found
      assert_equal before, settings_snapshot

      patch default_path('default:host-only'), params: { enabled: '0' }
      assert_response :see_other
      assert_redirected_to library_path
      assert_includes Bible270::ScriptureFrames.disabled_default_ids, 'default:host-only'
      [admin_path, frames_path].each do |path|
        get path
        if path == frames_path
          assert_response :see_other
          assert_redirected_to library_path
          follow_redirect!
        end
        assert_response :success
        assert_select 'article.b270-scripture-library-entry--default', count: 1 do
          assert_select 'summary', text: 'Host passage · KJV · Default · Disabled'
          assert_select 'blockquote', text: 'A host supplied passage.'
          assert_select 'button[aria-label="Enable Host passage"]', text: 'Enable'
        end
      end

      assert_equal host_yaml, File.read(host_path)
      File.write(host_path, "[]\n")
      before = settings_snapshot
      patch default_path('default:host-only'), params: { enabled: '1' }
      assert_response :not_found
      assert_equal before, settings_snapshot
      assert_equal bundled_yaml, File.binread(bundled_path)
      assert_equal "[]\n", File.read(host_path)
    end

    def test_main_admin_redirect_preserves_only_allowlisted_sorts_and_uses_the_library_anchor
      sign_in_as(@admin)
      Bible270::AdminController::READER_SORT_OPTIONS.each_key do |sort|
        patch default_path, params: { enabled: '0', return_to: 'admin', sort: sort }

        assert_response :see_other
        assert_redirected_to "#{admin_path}?sort=#{sort}#b270-scripture-frames"
      end
      [nil, '', 'https://evil.example/sort', 'first_name#bad', ['consistency'], { value: 'last_name' }].each do |sort|
        patch default_path, params: { enabled: '1', return_to: 'admin', sort: sort }

        assert_response :see_other
        assert_redirected_to "#{admin_path}?sort=first_name#b270-scripture-frames"
      end
    end

    def test_all_return_targets_always_redirect_directly_to_the_main_admin_panel
      sign_in_as(@admin)
      [nil, '', 'admin', 'texts', 'https://evil.example/path', '//evil.example/path', '/admin',
       'admin#bad', ['admin'], { value: 'admin' }].each do |target|
        ['consistency', 'https://evil.example/sort', ['last_name'], { value: 'last_name' }].each do |sort|
          patch default_path, params: { enabled: '0', return_to: target, sort: sort }

          assert_response :see_other
          assert_redirected_to library_path(sort == 'consistency' ? sort : 'first_name')
        end
      end
    end

    def test_invalid_state_uses_the_same_safe_admin_redirect
      sign_in_as(@admin)

      [nil, 'admin', 'texts', '//evil.example/path', ['admin'], { value: 'admin' }].each do |target|
        ['consistency', 'first_name#bad', ['last_name']].each do |sort|
          patch default_path, params: { enabled: ['0'], return_to: target, sort: sort }

          assert_response :see_other
          assert_redirected_to library_path(sort == 'consistency' ? sort : 'first_name')
          assert flash[:alert].present?
          assert_empty Bible270::ScriptureFrames.disabled_default_ids
        end
      end
    end

    def test_default_toggles_work_before_the_custom_table_migration_without_accessing_custom_storage
      sign_in_as(@admin)
      before = @custom.attributes
      Bible270::ScriptureFrames.stub(:custom_available?, false) do
        Bible270::ScriptureFrame.stub(:find, ->(*) { flunk 'Default toggles must not load custom records' }) do
          %w[0 1].each do |enabled|
            patch default_path, params: { enabled: enabled }

            assert_response :see_other
            assert_redirected_to library_path
            assert_equal enabled == '0', Bible270::ScriptureFrames.disabled_default_ids.include?(@frame.id)
          end
        end
      end
      assert_equal before, @custom.reload.attributes
    end

    def test_unavailable_default_settings_return_an_actionable_alert_without_changes
      sign_in_as(@admin)
      before = settings_snapshot
      Bible270::ScriptureFrames.stub(:default_settings_available?, false) do
        patch default_path, params: { enabled: '0', return_to: '//evil.example/path', sort: 'consistency' }
      end

      assert_response :see_other
      assert_redirected_to library_path('consistency')
      assert_match(%r{database}i, flash[:alert])
      assert_match(%r{migrat}i, flash[:alert])
      assert_equal before, settings_snapshot
    end

    def test_service_storage_argument_error_is_reported_with_a_safe_redirect
      sign_in_as(@admin)
      before = settings_snapshot
      message = 'Default Scripture frame settings are unavailable. Connect the database and run pending migrations, then try again.'
      failure = ->(id, enabled:) do
        assert_equal @frame.id, id
        assert_equal false, enabled
        raise ArgumentError, message
      end
      Bible270::ScriptureFrames.stub(:set_default_enabled!, failure) do
        patch default_path, params: { enabled: '0', return_to: 'admin', sort: '//evil.example' }
      end

      assert_response :see_other
      assert_redirected_to "#{admin_path}?sort=first_name#b270-scripture-frames"
      assert_match(%r{database}i, flash[:alert])
      assert_match(%r{migrat}i, flash[:alert])
      assert_equal before, settings_snapshot
    end

    def test_default_state_is_global_and_survives_a_new_run_and_revert
      sign_in_as(@admin)
      original_run = Bible270::PlanRun.current
      patch default_path, params: { enabled: '0' }
      assert_response :see_other
      assert_redirected_to library_path

      post "#{admin_path}/restart", params: {
        confirm_restart: '1', expected_run_id: original_run.id, start_date: (Bible270.today + 1).iso8601
      }
      assert_response :redirect
      fresh = Bible270::PlanRun.current
      refute_equal original_run.id, fresh.id
      assert_includes Bible270::ScriptureFrames.disabled_default_ids, @frame.id

      # A revert must preserve changes made after the restart, not restore a settings snapshot.
      patch default_path, params: { enabled: '1' }
      assert_response :see_other
      assert_redirected_to library_path
      other = @defaults.last
      patch default_path(other.id), params: { enabled: '0' }
      assert_response :see_other
      assert_redirected_to library_path
      before = Bible270::ScriptureFrames.disabled_default_ids.sort

      post "#{admin_path}/revert", params: { confirm_revert: '1', expected_run_id: fresh.id }

      assert_response :redirect
      assert_equal original_run.id, Bible270::PlanRun.current.id
      assert_equal before, Bible270::ScriptureFrames.disabled_default_ids.sort
      refute_includes Bible270::ScriptureFrames.disabled_default_ids, @frame.id
      assert_includes Bible270::ScriptureFrames.disabled_default_ids, other.id
    end

    def test_admin_changes_filter_public_random_frames_and_day_completion_without_hiding_previews
      needs_chapter_parts!
      sign_in_as(@admin)
      @defaults.each do |frame|
        patch default_path(frame.id), params: { enabled: '0' }
        assert_response :see_other
        assert_redirected_to library_path
      end
      get "#{mount}/scripture-frame"
      assert_response :no_content
      assert_equal 'no-store', response.headers['Cache-Control']

      patch default_path, params: { enabled: '1' }
      assert_response :see_other
      assert_redirected_to library_path
      public_session = open_session
      public_session.get "#{mount}/scripture-frame"
      assert_equal 200, public_session.response.status
      assert_equal @frame.to_h.transform_keys(&:to_s), public_session.response.parsed_body

      sign_in_as(@reader)
      @reader.mark_day_complete!(1)
      missing = @reader.checkoffs.find_by!(day: 1, track: 'nt', part: 0)
      missing.destroy!
      post "#{mount}/day/1/toggle/nt/0", params: { checked: '1' }, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      assert_response :success
      assert_select '[data-b270-completion-frame] [data-b270-scripture-reference]', text: @frame.reference
      assert_select '[data-b270-completion-frame] [data-b270-scripture-text]', text: @frame.text

      sign_in_as(@admin)
      patch default_path, params: { enabled: '0' }
      assert_response :see_other
      assert_redirected_to library_path
      sign_in_as(@reader)
      post "#{mount}/day/1/toggle/nt/0", params: { checked: '0' }, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      assert_response :success
      post "#{mount}/day/1/toggle/nt/0", params: { checked: '1' }, headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      assert_response :success
      assert_select '[data-b270-completion]', count: 1
      assert_select '[data-b270-completion-frame]', count: 0
      assert_select '.b270-day-complete', text: %r{Day 1 complete}
    end

  private

    def mount = Bible270.config.mount_at.chomp('/')
    def admin_path = "#{mount}/admin"
    def frames_path = "#{admin_path}/scripture-frames"
    def default_path(id = @frame.id) = "#{admin_path}/scripture-frame-defaults/#{id}"
    def library_path(sort = 'first_name') = "#{admin_path}?sort=#{sort}#b270-scripture-frames"

    def settings_snapshot
      Bible270::Setting.order(:key).map(&:attributes)
    end

    def create_reader(name, admin: false)
      email = "default-scripture-#{name}@example.org"
      Bible270::Reader.create!(provider: 'email', uid: email, email: email, display_name: name, admin: admin)
    end

    def sign_in_as(reader)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"
      assert_response :redirect
    end

    def assert_toggles_hidden
      before = settings_snapshot
      %w[0 1].each do |enabled|
        Bible270::ScriptureFrames.stub(:set_default_enabled!, ->(*) { flunk 'Unauthorized requests must not call the default settings service' }) do
          patch default_path, params: { enabled: enabled, view: 'admin', admin: true, site_admin: true }
          assert_response :not_found
        end
        assert_equal before, settings_snapshot
      end
    end

    def assert_toggles_available(admin)
      sign_in_as(admin)
      catalog = @defaults.map(&:to_h)
      yaml_path = Bible270::Engine.root.join('config/scripture_frames.yml')
      yaml = File.binread(yaml_path)
      custom = Bible270::ScriptureFrame.order(:id).map(&:attributes)
      before_count = Bible270::Setting.count

      2.times do
        patch default_path, params: { enabled: '0', reference: 'Forged reference', text: 'Forged text',
                                      scripture_frame: { enabled: '1', text: 'Forged custom text' } }
        assert_response :see_other
        assert_redirected_to library_path
        assert flash[:notice].present?
        assert_equal [@frame.id], Bible270::ScriptureFrames.disabled_default_ids
        assert_equal before_count + 1, Bible270::Setting.count
      end
      2.times do
        patch default_path, params: { enabled: '1' }
        assert_response :see_other
        assert_redirected_to library_path
        assert flash[:notice].present?
        assert_empty Bible270::ScriptureFrames.disabled_default_ids
        assert_equal before_count, Bible270::Setting.count
      end

      assert_equal catalog, Bible270::ScriptureFrames.defaults.map(&:to_h)
      assert_equal yaml, File.binread(yaml_path)
      assert_equal custom, Bible270::ScriptureFrame.order(:id).map(&:attributes)
    end
  end
end
