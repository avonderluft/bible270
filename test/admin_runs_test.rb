# frozen_string_literal: true

require_relative 'support/admin_runs_test_case'

if RAILS_LOADED
  class AdminRunsTest < Bible270AdminRunsTestCase
    def test_restart_preserves_all_history_and_starts_admins_fresh_in_the_new_group
      @reader.update!(started_on: Bible270.today - 3)
      @reader.mark_through!(3)
      [@site_admin, @admin].each do |reader|
        reader.update!(started_on: Bible270.today - 4)
        reader.mark_through!(1)
      end
      @site_admin.archive!
      old_memberships = [@site_admin, @admin].to_h { |reader| [reader.id, reader.participation] }
      reflection = @reader.comments.create!(day: 1, body: 'Keep this reflection')
      checkoffs = Bible270::Checkoff.order(:id).map(&:attributes)
      membership_ids = Bible270::Participation.order(:id).pluck(:id)
      Bible270::Setting.close_enrollment!

      post restart_path, params: restart_params

      assert_redirected_to admin_path
      refute_equal @run.id, Bible270::PlanRun.current.id
      assert_equal Bible270.today + 1, Bible270::Setting.run_start_date
      refute Bible270::Setting.enrollment_closed?
      assert_equal checkoffs, Bible270::Checkoff.order(:id).map(&:attributes)
      assert_equal membership_ids, Bible270::Participation.where(id: membership_ids).order(:id).pluck(:id)
      assert_equal membership_ids.size + 2, Bible270::Participation.count
      assert Bible270::Comment.exists?(reflection.id)
      assert_equal [@site_admin.id, @admin.id].sort, Bible270::Reader.active.order(:id).pluck(:id)
      [@site_admin, @admin].each do |reader|
        refute reader.reload.alumni?
        assert Bible270.config.admin?(reader)
        assert_equal Bible270::PlanRun.current.id, reader.participation.plan_run_id
        refute_equal old_memberships.fetch(reader.id).id, reader.participation.id
        assert_equal 2, reader.participations.count
        assert_nil reader.started_on
        assert_nil reader.participation.started_on
        assert_equal 0, reader.days_completed
        assert_empty reader.checkoffs
        old_membership = old_memberships.fetch(reader.id).reload
        refute old_membership.active?
        assert_equal Bible270.today - 4, old_membership.started_on
        assert_equal Bible270.today - 4, old_membership.frozen_start_date
        assert_operator old_membership.checkoffs.count, :>, 0
      end
      assert @admin.admin?
      refute @site_admin.admin?
      assert Bible270.config.site_admin?(@site_admin)
      assert @reader.reload.alumni?
      assert_equal 3, @reader.days_completed
      assert_equal Bible270.today - 3, @reader.effective_start_date
      follow_redirect!
      assert_response :success
      assert_select 'details#b270-alumni:not([open])'
      assert_select '#b270-alumni .b270-li', count: 1
      assert_select '.lede', text: %r{2 readers taking part}
      newcomer = create_reader('New Group')
      assert_equal Bible270::PlanRun.current.id, newcomer.participation.plan_run_id
      assert_equal [@site_admin.id, @admin.id, newcomer.id].sort, Bible270::Reader.active.order(:id).pluck(:id)
    end

    def test_restart_rejects_missing_confirmation_invalid_dates_and_stale_or_missing_run_ids
      @reader.mark_through!(1)
      original = [Bible270::PlanRun.count, Bible270::Participation.order(:id).pluck(:id, :active), Bible270::Checkoff.count]
      [restart_params.except(:confirm_restart), restart_params.merge(confirm_restart: '0'),
       restart_params.merge(start_date: ''), restart_params.merge(start_date: 'not a date'),
       restart_params.except(:expected_run_id), restart_params.merge(expected_run_id: @run.id + 100)].each do |parameters|
        post restart_path, params: parameters

        assert_redirected_to admin_path
        assert flash[:alert].present?
        assert_equal @run.id, Bible270::PlanRun.current.id
        assert_equal original, [Bible270::PlanRun.count, Bible270::Participation.order(:id).pluck(:id, :active), Bible270::Checkoff.count]
      end
    end

    def test_restart_form_has_inline_controls_and_native_submit_confirmation
      get admin_path

      assert_response :success
      assert_select "form.b270-startform.b270-restart-form[action='#{restart_path}'][data-b270-admin-confirm]" do |forms|
        assert_match(%r{Admins and Site-admins.*start fresh}, forms.first['data-b270-admin-confirm'])
        assert_includes forms.first['data-b270-admin-confirm'], 'zero progress and no personal start date'
        assert_includes forms.first['data-b270-admin-confirm'], 'Other readers will become alumni'
        refute_includes forms.first['data-b270-admin-confirm'], 'including you, will become alumni'
        assert_select '> label[for="b270-restart-date"]', text: 'Start date:'
        assert_select '> input#b270-restart-date[type="date"][name="start_date"][required]'
        assert_select "input[type='hidden'][name='expected_run_id'][value='#{@run.id}']"
        assert_select 'input[type="hidden"][name="confirm_restart"][value="1"]'
        assert_select 'input[type="checkbox"][name="plus95_enabled"][value="1"]:not([checked])', count: 1
        assert_select 'input[type="checkbox"]', count: 1
        assert_select '> input[type="submit"][value="Start a new run"]'
      end
      refute_includes response.body, 'I understand that all current readers'
      assert_select 'script[data-b270-admin-confirmations]', count: 1
      assert_operator response.body.index('Start a new run'), :<, response.body.index('Show Alumni')
      refute_match(%r{delete reflections}i, response.body)
    end

    def test_configured_email_site_admin_keeps_access_and_can_change_own_status_across_runs
      assert_site_admin_survives_restarts
    end

    def test_configured_resolver_site_admin_keeps_access_and_can_change_own_status_across_runs
      id = @site_admin.id
      Bible270.config.admin_emails = []
      Bible270.config.admin_resolver = ->(reader) { reader.id == id }

      assert_site_admin_survives_restarts
    end

    def test_non_admin_cannot_restart_or_change_membership
      sign_in_as(@reader)
      post restart_path, params: restart_params
      assert_response :not_found
      patch participation_path(@admin), params: { status: 'alumni', expected_run_id: @run.id }
      assert_response :not_found
      assert_equal @run.id, Bible270::PlanRun.current.id
      refute @admin.reload.alumni?
    end
  end
end
