# frozen_string_literal: true

require_relative 'support/admin_runs_test_case'

if RAILS_LOADED
  class AdminPlus95Test < Bible270AdminRunsTestCase
    def test_forms_offer_an_unchecked_restart_option_and_an_explicit_current_run_setting
      assert_equal Bible270::Plan::DAYS, @run.plan_days
      refute @run.plus95_enabled?

      get admin_path

      assert_response :success
      assert_select 'h3', text: 'Plan length: 270 days'
      assert_select "form[action='#{plus95_path}']" do
        assert_select 'input[name="_method"][value="patch"]'
        assert_select "input[name='expected_run_id'][value='#{@run.id}']"
        assert_select 'input[name="plus95_enabled"][value="1"]'
      end
      assert_select "form[action='#{restart_path}']" do
        assert_select 'label[for="b270-restart-plus95"]', text: 'Include +95 (365 days)'
        assert_select 'input#b270-restart-plus95[type="checkbox"][name="plus95_enabled"][value="1"]:not([checked])'
      end

      patch plus95_path, params: plus95_params('1')
      assert_redirected_to admin_path
      follow_redirect!

      assert_response :success
      assert_select 'h3', text: 'Plan length: 365 days'
      end_date = Bible270.config.start_date + Bible270::Plan::EXTENDED_DAYS - 1
      assert_select '.b270-startline strong', text: end_date.strftime('%B %-d, %Y')
      assert_select "form[action='#{plus95_path}'] input[name='plus95_enabled'][value='0']"
      assert_select 'input#b270-restart-plus95:not([checked])'
    end

    def test_disabling_and_reenabling_keeps_checkoffs_and_reflections
      patch plus95_path, params: plus95_params('1')
      assert_redirected_to admin_path
      assert_equal Bible270::Plan::EXTENDED_DAYS, @run.reload.plan_days
      store_extension_history
      before = history_snapshot

      # Repeated requests set the desired state rather than inverting it.
      2.times do
        patch plus95_path, params: plus95_params('0')

        assert_redirected_to admin_path
        assert_equal @run.id, Bible270::PlanRun.current.id
        assert_equal Bible270::Plan::DAYS, @run.reload.plan_days
        assert_equal before, history_snapshot
      end

      patch plus95_path, params: plus95_params('1')

      assert_redirected_to admin_path
      assert_equal Bible270::Plan::EXTENDED_DAYS, @run.reload.plan_days
      assert_equal before, history_snapshot
    end

    def test_admin_stats_and_bulk_edits_follow_run_length_without_clearing_hidden_days
      day = Bible270::Plan::DAYS + 1
      path = reader_path(@reader)
      patch plus95_path, params: plus95_params('1')
      post "#{path}/days/#{day}"
      assert_redirected_to "#{path}#day-#{day}"
      assert_equal 1, @reader.reload.reload_progress.days_completed

      get path
      assert_select '.b270-completions-summary', text: %r{1/365 days}
      assert_select "form#day-#{day}", count: 1
      assert_select 'input[name="day"][type="number"][max="365"]', count: 2
      get admin_path
      assert_select '#b270-active-readers .b270-li', text: %r{1/365 days}, count: 1

      patch plus95_path, params: plus95_params('0')
      patch "#{path}/through", params: { day: 0 }
      assert_redirected_to path
      assert_equal [day], @reader.checkoffs.distinct.pluck(:day)
      assert_empty Bible270::Reader.completed_days_by_id
      assert_empty Bible270::Checkoff.recent_activity_by_reader([@reader.id])
      assert_empty Bible270::Reader.completers_for(day)

      get path
      assert_select '.b270-completions-summary', text: %r{0/270 days}
      assert_select "form#day-#{day}", count: 0
      assert_select 'input[name="day"][type="number"][max="270"]', count: 2

      patch plus95_path, params: plus95_params('1')
      assert_equal 1, Bible270::Reader.completed_days_by_id[@reader.id]
      assert_equal day, Bible270::Checkoff.recent_activity_by_reader([@reader.id]).fetch(@reader.id).day
      assert_equal [@reader.id], Bible270::Reader.completers_for(day).map(&:id)

      post restart_path, params: restart_params
      get path
      assert_select '#b270-run-history td', text: '1/365'
      assert_select '.b270-completions-summary', text: %r{1/365 days}
    end

    def test_alumni_completion_disclosure_counts_full_runs_by_length_and_shows_local_dates
      previous_zone = Bible270.config.time_zone
      Bible270.config.time_zone = 'America/Los_Angeles'
      @reader.archive!
      incomplete = create_reader('Nearly finished')
      incomplete.archive!
      first = record_past_run(@reader, days: 270, finished_at: Time.utc(2024, 9, 20, 12))
      record_past_run(@reader, days: 270, finished_at: Time.utc(2025, 8, 2, 2))
      record_past_run(@reader, days: 365, finished_at: Time.utc(2025, 11, 15, 12))
      record_past_run(incomplete, days: 365, finished_at: Time.utc(2025, 11, 30, 12), missing_final_part: true)
      Bible270::Checkoff.insert_all!([
        { reader_id: @reader.id, participation_id: first.id, day: 271, track: 'nt', part: 0, created_at: Time.utc(2025, 1, 1) }
      ])

      get admin_path

      assert_response :success
      assert_select '#b270-active-readers .b270-alumni-completions', count: 0
      assert_select '#b270-alumni details.b270-alumni-completions:not([open])', count: 1 do |disclosures|
        assert_includes disclosures.first.ancestors('.b270-li').first.text, @reader.display_name
        assert_select '> summary', text: 'Completed: 270 days ×2 · 365 days ×1'
        assert_select '> div time', count: 3 do |dates|
          assert_equal(%w[2025-08-01 2024-09-20 2025-11-15], dates.map { |node| node['datetime'] })
          assert_equal ['Aug 1, 2025', 'Sep 20, 2024', 'Nov 15, 2025'], dates.map(&:text)
        end
      end
    ensure
      Bible270.config.time_zone = previous_zone
    end

    def test_consistency_evaluates_days_beyond_270_only_when_enabled
      today = Bible270.today
      @reader.update!(created_at: (today - 300).to_time)
      @reader.participation.update!(joined_at: (today - 300).to_time)
      @reader.set_start_date!(today - 300)
      assert_equal 270, Bible270::ReaderConsistency.new(readers: [@reader], today: today).for(@reader).days_evaluated

      patch plus95_path, params: plus95_params('1')
      @reader.reload_progress
      assert_equal 300, Bible270::ReaderConsistency.new(readers: [@reader], today: today).for(@reader).days_evaluated
    end

    def test_site_admin_can_enable_plus95
      sign_in_as(@site_admin)
      refute @site_admin.admin?

      patch plus95_path, params: plus95_params('1')

      assert_redirected_to admin_path
      assert @run.reload.plus95_enabled?
    end

    def test_visitors_readers_and_admins_in_reader_view_cannot_change_plus95
      delete "#{mount}/sign_out"
      patch plus95_path, params: plus95_params('1')
      assert_response :not_found

      sign_in_as(@reader)
      patch plus95_path, params: plus95_params('1')
      assert_response :not_found

      sign_in_as(@admin)
      patch "#{admin_path}/view", params: { view: 'reader' }
      assert_response :see_other
      get admin_path
      assert_response :success
      assert_select "form[action='#{plus95_path}']", count: 0
      patch plus95_path, params: plus95_params('1')
      assert_response :not_found
      refute @run.reload.plus95_enabled?
    end

    def test_toggle_requires_an_explicit_value_and_current_run_id
      [plus95_params('1').except(:plus95_enabled), plus95_params('true'), plus95_params(['1']),
       plus95_params('1').except(:expected_run_id), plus95_params('1').merge(expected_run_id: @run.id + 1)].each do |parameters|
        patch plus95_path, params: parameters

        assert_redirected_to admin_path
        assert flash[:alert].present?
        refute @run.reload.plus95_enabled?
      end
    end

    def test_toggle_rejects_a_run_archived_before_the_lock_was_acquired
      stale_run = Bible270::PlanRun.current
      fresh_run = Bible270::PlanRun.restart!(start_date: Bible270.today, expected_run_id: stale_run.id)
      assert stale_run.current?, 'the form target was loaded before restart'

      Bible270::PlanRun.stub(:current, stale_run) do
        patch plus95_path, params: plus95_params('1')
      end

      assert_redirected_to admin_path
      assert_includes flash[:alert], 'run changed'
      refute fresh_run.reload.plus95_enabled?
      refute stale_run.reload.plus95_enabled?
    end

    def test_unmigrated_schema_hides_controls_and_rejects_plus95_but_allows_standard_restart
      original_columns = Bible270::PlanRun.ignored_columns
      Bible270::PlanRun.ignored_columns = original_columns + ['plus95_enabled']
      Bible270::PlanRun.reset_column_information
      refute @run.reload.plus95_available?
      refute @run.plus95_enabled?
      assert_equal Bible270::Plan::DAYS, @run.plan_days

      get admin_path
      assert_response :success
      assert_select "form[action='#{plus95_path}']", count: 0
      assert_select 'input#b270-restart-plus95', count: 0

      patch plus95_path, params: plus95_params('1')
      assert_redirected_to admin_path
      assert_includes flash[:alert], 'database migration'

      post restart_path, params: restart_params.merge(plus95_enabled: '1')
      assert_redirected_to admin_path
      assert_includes flash[:alert], 'database migration'
      assert_equal @run.id, Bible270::PlanRun.current.id

      post restart_path, params: restart_params
      assert_redirected_to admin_path
      refute_equal @run.id, Bible270::PlanRun.current.id
      assert_equal Bible270::Plan::DAYS, Bible270::PlanRun.current.plan_days
    ensure
      Bible270::PlanRun.ignored_columns = original_columns
      Bible270::PlanRun.reset_column_information
    end

    def test_new_run_opt_in_does_not_change_the_previous_run_setting
      post restart_path, params: restart_params.merge(plus95_enabled: '1')

      assert_redirected_to admin_path
      fresh_run = Bible270::PlanRun.current
      assert_equal Bible270::Plan::EXTENDED_DAYS, fresh_run.plan_days
      refute @run.reload.plus95_enabled?
    end

    def test_restart_defaults_to_270_and_revert_restores_the_previous_runs_own_setting_and_progress
      patch plus95_path, params: plus95_params('1')
      store_extension_history
      before = history_snapshot
      old_membership_id = @admin.participation.id

      post restart_path, params: restart_params

      assert_redirected_to admin_path
      fresh_run = Bible270::PlanRun.current
      refute_equal @run.id, fresh_run.id
      assert_equal Bible270::Plan::DAYS, fresh_run.plan_days
      assert @run.reload.plus95_enabled?
      assert_empty @admin.reload.checkoffs
      assert_equal before, history_snapshot

      post "#{admin_path}/revert", params: { expected_run_id: fresh_run.id, confirm_revert: '1' }

      assert_redirected_to admin_path
      assert_equal @run.id, Bible270::PlanRun.current.id
      assert_equal Bible270::Plan::EXTENDED_DAYS, Bible270::PlanRun.current.plan_days
      refute fresh_run.reload.plus95_enabled?
      assert_equal old_membership_id, @admin.reload.participation.id
      assert_equal [Bible270::Plan::DAYS + 1], @admin.checkoffs.pluck(:day)
      assert_equal before, history_snapshot
    end

  private

    def plus95_path = "#{admin_path}/run-plus95"
    def plus95_params(value) = { expected_run_id: @run.id, plus95_enabled: value }

    def record_past_run(reader, days:, finished_at:, missing_final_part: false)
      run = Bible270::PlanRun.create!(plus95_enabled: days == 365, archived_at: finished_at + 1.day)
      membership = reader.participations.create!(plan_run: run, active: false, joined_at: finished_at - days.days)
      rows = (1..days).flat_map do |day|
        Bible270::Plan.present_tracks(day).flat_map do |track|
          Bible270::Plan.parts_for(day, track).each_index.filter_map do |part|
            next if missing_final_part && day == days && track == 'pp' && part.zero?

            # The last check-off is for an early reading, not the last numbered day.
            at = day == 1 && track == 'nt' && part.zero? ? finished_at : finished_at - 2.days
            { reader_id: reader.id, participation_id: membership.id, day: day, track: track, part: part, created_at: at }
          end
        end
      end
      Bible270::Checkoff.insert_all!(rows)
      membership
    end

    def store_extension_history
      # Seed persisted history without depending on reader-facing write routes.
      day = Bible270::Plan::DAYS + 1
      Bible270::Checkoff.insert_all!([{ reader_id: @admin.id, participation_id: @admin.participation.id, day: day, track: 'nt', part: 0 }])
      Bible270::Comment.insert_all!([{ reader_id: @admin.id, day: day, body: 'Keep this reflection' }])
    end

    def history_snapshot
      [Bible270::Checkoff, Bible270::Comment].map { |model| model.order(:id).map(&:attributes) }
    end
  end
end
