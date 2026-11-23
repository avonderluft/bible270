# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class ProfilePlus95Test < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @tagline = Bible270.config.tagline
      @reader = create_reader('reader')
      @other = create_reader('other')
      @run = Bible270::PlanRun.current
    end

    def teardown
      Bible270.config.tagline = @tagline
    end

    def test_profile_changes_own_length_and_overview_without_changing_run_or_other_readers
      sign_in
      get profile_path
      assert_response :success
      assert_select "#b270-profile-plus95 form[action='#{plus95_path}']" do
        assert_select 'option[selected]', text: 'Run default'
        assert_select 'option[value="1"]', text: '365 days (+95)'
      end

      patch plus95_path, params: params_for('1').merge(reader_id: @other.id, first_name: 'Ignored')
      assert_response :see_other
      assert_redirected_to profile_path
      follow_redirect!
      assert_select '#b270-profile-plus95 h2', text: 'Plan length: 365 days'
      assert_select '#b270-profile-plus95 option[selected]', text: '365 days (+95)'
      assert_nil @other.reload.participation.plus95_override
      refute @run.reload.plus95_enabled?
      assert_equal 'Reader', @reader.reload.first_name
      assert_overview(365)
      get "#{mount}/day/271"
      assert_response :success
    end

    def test_readers_can_use_270_days_or_follow_an_extended_run_without_erasing_checkoffs
      @run.update!(plus95_enabled: true)
      sign_in
      assert_overview(365)
      assert @reader.reload.reload_progress.mark_day_complete!(271)
      count = @reader.checkoffs.count

      patch plus95_path, params: params_for('0')
      assert_response :see_other
      assert_overview(270)
      assert_equal count, @reader.checkoffs.count
      get "#{mount}/day/271"
      assert_redirected_to "#{mount}/"

      patch plus95_path, params: params_for('default')
      assert_response :see_other
      assert_nil @reader.reload.reload_progress.participation.plus95_override
      assert @reader.day_complete?(271)
      assert_overview(365)
    end

    def test_visitors_see_run_length_and_hosts_keep_custom_taglines
      Bible270.config.tagline = 'A 270-day journey through Scripture'
      assert_overview(270)
      @run.update!(plus95_enabled: true)
      assert_overview(365)
      Bible270.config.tagline = 'Journeying through Scripture in 9 months'
      assert_overview(365)
      Bible270.config.tagline = 'Reading together at our own pace'
      get "#{mount}/"
      assert_select 'p.b270-eyebrow', text: Bible270.config.tagline
    end

    def test_visitors_and_alumni_cannot_change_length
      patch plus95_path, params: params_for('1')
      assert_response :redirect
      assert_includes response.location, "#{mount}/sign_in"
      assert_nil @reader.reload.participation.plus95_override

      @reader.archive!
      sign_in
      get profile_path
      assert_select "form[action='#{plus95_path}']", count: 0
      patch plus95_path, params: params_for('1')
      assert_redirected_to profile_path
      assert_includes flash[:alert], 'Only active readers'
      assert_nil @reader.reload.participation.plus95_override
    end

    def test_stale_membership_and_invalid_choice_do_not_change_progress
      sign_in
      old_membership = @reader.participation
      stale = params_for('1')
      Bible270::PlanRun.restart!(start_date: Bible270.today, expected_run_id: @run.id)
      @reader.reload.activate!

      [stale, params_for(['1']), params_for('1').except(:participation_id)].each do |parameters|
        patch plus95_path, params: parameters
        assert_redirected_to profile_path
        assert flash[:alert].present?
        assert_nil @reader.reload.participation.plus95_override
      end
      assert_nil old_membership.reload.plus95_override
    end

    def test_unavailable_migration_hides_control_and_rejects_saves
      model = Bible270::Participation
      saved_columns = model.ignored_columns
      model.ignored_columns += ['plus95_override']
      model.reset_column_information
      sign_in
      get profile_path
      assert_response :success
      assert_select '#b270-profile-plus95', count: 0
      patch plus95_path, params: params_for('1')
      assert_redirected_to profile_path
      assert_includes flash[:alert], 'database'
    ensure
      model.ignored_columns = saved_columns
      model.reset_column_information
    end

  private

    def create_reader(name)
      email = "#{name}-plus95@example.org"
      Bible270::Reader.create!(provider: 'email', uid: email, email: email, display_name: "#{name.capitalize} Plus", first_name: name.capitalize, last_name: 'Plus')
    end

    def mount = Bible270.config.mount_at.chomp('/')
    def profile_path = "#{mount}/profile"
    def plus95_path = "#{profile_path}/plus95"
    def params_for(value) = { participation_id: @reader.participation.id, plus95_override: value }

    def sign_in
      _record, raw = Bible270::SignInToken.issue!(@reader.email)
      get "#{mount}/sign_in/email/#{raw}"
    end

    def assert_overview(days)
      get "#{mount}/"
      assert_response :success
      assert_select 'p.b270-eyebrow', text: "A #{days}-day journey through Scripture"
      description = if days == 365
                      'Daily passages from the Old Testament once, and from the New Testament and Psalms/Proverbs twice'
                    else
                      'Daily passages from the Old Testament, New Testament, and Psalms/Proverbs'
                    end
      assert_select 'p.lede', text: %r{\A#{Regexp.escape(description)} —}
      assert_select 'details.b270-index > summary', text: "View all #{days} days"
    end
  end
end
