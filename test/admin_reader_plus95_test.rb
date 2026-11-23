# frozen_string_literal: true

require_relative 'support/admin_runs_test_case'

if RAILS_LOADED
  class AdminReaderPlus95Test < Bible270AdminRunsTestCase
    def test_active_reader_can_use_either_length_or_restore_the_run_default
      get reader_path(@reader)
      assert_response :success
      assert_select "form[action='#{plus95_path}']" do
        assert_select 'input[name="_method"][value="patch"]'
        assert_select "input[type='hidden'][name='participation_id'][value='#{@reader.participation.id}']"
        assert_select 'select[name="plus95_override"] option', count: 3
        assert_select 'option[value="default"][selected]', text: 'Run default'
        assert_select 'option[value="0"]', text: '270 days'
        assert_select 'option[value="1"]', text: '365 days (+95)'
      end
      assert_select '#b270-reader-plus95 h2', text: 'Plan length: 270 days'

      patch plus95_path, params: plus95_params('1')
      assert_redirected_to reader_path(@reader)
      assert_equal true, @reader.reload.participation.plus95_override
      assert_equal 270, @run.reload.plan_days
      assert_equal 270, @site_admin.reload.participation.plan_days
      follow_redirect!
      assert_select '#b270-reader-plus95 h2', text: 'Plan length: 365 days'
      assert_select '#b270-reader-plus95 option[selected]', text: '365 days (+95)'

      Bible270::PlanRun.update_plus95!(enabled: true, expected_run_id: @run.id)
      patch plus95_path, params: plus95_params('0')
      assert_redirected_to reader_path(@reader)
      assert_equal false, @reader.reload.participation.plus95_override
      follow_redirect!
      assert_select '#b270-reader-plus95 h2', text: 'Plan length: 270 days'
      assert_select '#b270-reader-plus95 option[selected]', text: '270 days'

      patch plus95_path, params: plus95_params('default')
      assert_redirected_to reader_path(@reader)
      assert_nil @reader.reload.participation.plus95_override
      assert_equal 365, @run.reload.plan_days
      follow_redirect!
      assert_select '#b270-reader-plus95 h2', text: 'Plan length: 365 days'
      assert_select '#b270-reader-plus95 option[selected]', text: 'Run default'
    end

    def test_overrides_scope_progress_to_each_reader_without_erasing_checkoffs
      day = Bible270::Plan::DAYS + 1
      patch plus95_path, params: plus95_params('1')
      assert @reader.reload.reload_progress.mark_day_complete!(day)
      refute @site_admin.reload.reload_progress.mark_day_complete!(day)
      assert_equal [@reader.id], Bible270::Reader.completers_for(day).map(&:id)
      assert_equal({ @reader.id => 1 }, Bible270::Reader.completed_days_by_id)

      Bible270::PlanRun.update_plus95!(enabled: true, expected_run_id: @run.id)
      assert @site_admin.reload.reload_progress.mark_day_complete!(day)
      patch plus95_path, params: plus95_params('0')
      assert_equal({ @site_admin.id => 1 }, Bible270::Reader.completed_days_by_id)
      assert_equal [@site_admin.id], Bible270::Reader.completers_for(day).map(&:id)
      assert_equal [day], @reader.checkoffs.distinct.pluck(:day)
      assert_equal 0, @reader.reload.reload_progress.days_completed

      patch plus95_path, params: plus95_params('default')
      assert_equal({ @reader.id => 1, @site_admin.id => 1 }, Bible270::Reader.completed_days_by_id)
    end

    def test_override_stays_with_its_membership_on_restart_and_revert
      patch plus95_path, params: plus95_params('1')
      old_membership = @reader.reload.participation
      post restart_path, params: restart_params
      fresh_run = Bible270::PlanRun.current
      @reader.reload.activate!
      assert_nil @reader.participation.plus95_override
      assert_equal 270, @reader.plan_days
      assert_equal 365, old_membership.reload.plan_days

      post "#{admin_path}/revert", params: { expected_run_id: fresh_run.id, confirm_revert: '1' }
      assert_equal old_membership.id, @reader.reload.reload_progress.participation.id
      assert_equal 365, @reader.plan_days
    end

    def test_only_admins_in_admin_view_can_set_an_override
      delete "#{mount}/sign_out"
      patch plus95_path, params: plus95_params('1')
      assert_response :not_found

      sign_in_as(@reader)
      patch plus95_path, params: plus95_params('1')
      assert_response :not_found

      sign_in_as(@admin)
      patch "#{admin_path}/view", params: { view: 'reader' }
      assert_response :see_other
      patch plus95_path, params: plus95_params('1')
      assert_response :not_found
      assert_nil @reader.reload.participation.plus95_override
    end

    def test_alumni_have_no_control_and_cannot_change_their_override
      @reader.archive!
      get reader_path(@reader)
      assert_response :success
      assert_select "form[action='#{plus95_path}']", count: 0

      patch plus95_path, params: plus95_params('1')
      assert_redirected_to reader_path(@reader)
      assert_includes flash[:alert], 'read-only'
      assert_nil @reader.reload.participation.plus95_override
    end

    def test_old_form_cannot_update_a_replacement_membership
      old_membership = @reader.participation
      parameters = plus95_params('1')
      post restart_path, params: restart_params
      assert_redirected_to admin_path
      @reader.reload.activate!
      refute_equal old_membership.id, @reader.participation.id

      patch plus95_path, params: parameters
      assert_redirected_to admin_path
      assert_includes flash[:alert], 'run changed'
      assert_nil old_membership.reload.plus95_override
      assert_nil @reader.reload.participation.plus95_override
    end

    def test_membership_id_is_mandatory_and_must_belong_to_the_target
      [plus95_params('1').except(:participation_id), plus95_params('1').merge(participation_id: ''),
       plus95_params('1').merge(participation_id: @admin.participation.id)].each do |parameters|
        patch plus95_path, params: parameters
        assert_redirected_to admin_path
        assert flash[:alert].present?
        assert_nil @reader.reload.participation.plus95_override
        assert_nil @admin.reload.participation.plus95_override
      end
    end

    def test_override_requires_an_explicit_choice
      @reader.participation.update!(plus95_override: true)
      [plus95_params('0').except(:plus95_override), plus95_params('false'), plus95_params(['0'])].each do |parameters|
        patch plus95_path, params: parameters
        assert_redirected_to reader_path(@reader)
        assert flash[:alert].present?
        assert_equal true, @reader.reload.participation.plus95_override
      end
    end

    def test_unmigrated_participations_hide_the_form_and_reject_updates
      model = Bible270::Participation
      original_columns = model.ignored_columns
      Bible270::PlanRun.update_plus95!(enabled: true, expected_run_id: @run.id)
      model.ignored_columns = original_columns + ['plus95_override']
      model.reset_column_information

      get reader_path(@reader)
      assert_response :success
      assert_select '#b270-reader-plus95 h2', text: 'Plan length: 365 days'
      assert_select "form[action='#{plus95_path}']", count: 0
      assert_select '#b270-reader-plus95 .b270-hint', text: %r{database migration}

      patch plus95_path, params: plus95_params('1')
      assert_redirected_to reader_path(@reader)
      assert_includes flash[:alert], 'database migration'
    ensure
      model.ignored_columns = original_columns
      model.reset_column_information
    end

  private

    def plus95_path = "#{reader_path(@reader)}/plus95"
    def plus95_params(value) = { participation_id: @reader.participation.id, plus95_override: value }
  end
end
