# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class AdminRunSafetyTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_config = %i[admin_emails admin_resolver mention_notifications registration_notice_emails start_date].to_h do |key|
        [key, Bible270.config.public_send(key)]
      end
      Bible270.config.admin_resolver = nil
      Bible270.config.mention_notifications = false
      Bible270.config.registration_notice_emails = []
      Bible270.config.start_date = Bible270.today - 9
      @boss = reader('Boss')
      @admin = reader('Admin', admin: true)
      @reader = reader('Reader')
      Bible270.config.admin_emails = [@boss.email]
      @run = Bible270::PlanRun.current
      sign_in_as(@admin)
    end

    def teardown
      @previous_config&.each { |key, value| Bible270.config.public_send("#{key}=", value) }
    end

    def test_calendar_forms_identify_the_run_they_change
      Bible270::Setting.set_run_start_date!(Bible270.today)
      get "#{mount}/admin"

      assert_response :success
      assert_select "form[action='#{mount}/admin/run-start']", count: 2 do |forms|
        forms.each do |form|
          assert_equal @run.id.to_s, form.at_css('input[name="expected_run_id"]')['value']
        end
      end
    end

    def test_a_stale_calendar_change_cannot_change_the_replacement_run
      fresh = restart_run
      old_date = @reader.reload.effective_start_date
      patch "#{mount}/admin/run-start", params: { expected_run_id: @run.id, start_date: '2030-01-01' }

      assert_redirected_to "#{mount}/admin"
      assert_match(%r{run changed}, flash[:alert])
      assert_equal fresh.start_date, Bible270::Setting.run_start_date
      assert_equal old_date, @reader.reload.effective_start_date
    end

    def test_a_stale_calendar_reset_cannot_reset_the_replacement_run
      fresh = restart_run
      delete "#{mount}/admin/run-start", params: { expected_run_id: @run.id }

      assert_redirected_to "#{mount}/admin"
      assert_equal fresh.start_date, Bible270::Setting.run_start_date
      assert Bible270::Setting.run_start_date_overridden?
    end

    def test_current_calendar_changes_and_reset_still_work
      patch "#{mount}/admin/run-start", params: { expected_run_id: @run.id, start_date: '2027-01-01' }
      assert_equal Date.new(2027, 1, 1), Bible270::Setting.run_start_date

      delete "#{mount}/admin/run-start", params: { expected_run_id: @run.id }
      assert_equal Bible270.config.start_date, Bible270::Setting.run_start_date
    end

    def test_all_admin_progress_forms_identify_the_membership
      get "#{mount}/admin/readers/#{@reader.id}"

      assert_response :success
      forms = css_select('form').select do |form|
        form['action'].match?(%r{/readers/#{@reader.id}/(?:start|through|days/\d+)\z})
      end
      assert_equal Bible270::Plan::DAYS + 3, forms.size
      forms.each do |form|
        assert_equal @reader.participation.id.to_s, form.at_css('input[name="participation_id"]')['value']
      end
    end

    def test_old_admin_progress_forms_cannot_change_a_returning_readers_new_run
      old_membership = @reader.participation
      @reader.mark_day_complete!(1)
      restart_run
      @reader.reload.activate!
      @reader.mark_day_complete!(2)
      new_ids = @reader.checkoffs.pluck(:id)
      old_ids = old_membership.checkoffs.pluck(:id)
      params = { participation_id: old_membership.id, day: 0, start_date: '2030-01-01' }

      patch "#{mount}/admin/readers/#{@reader.id}/through", params: params
      assert_redirected_to "#{mount}/admin"
      patch "#{mount}/admin/readers/#{@reader.id}/start", params: params
      assert_redirected_to "#{mount}/admin"
      post "#{mount}/admin/readers/#{@reader.id}/days/2", params: params
      assert_redirected_to "#{mount}/admin"

      assert_equal new_ids, @reader.reload.checkoffs.pluck(:id)
      assert_equal old_ids, old_membership.checkoffs.pluck(:id)
      assert_nil @reader.started_on
    end

    def test_old_admin_progress_forms_cannot_change_automatically_enrolled_admin_memberships
      old_memberships = [@boss, @admin].to_h do |reader|
        reader.update!(started_on: Bible270.today - 3)
        reader.mark_day_complete!(1)
        [reader.id, reader.participation]
      end
      fresh = restart_run
      [@boss, @admin].each do |reader|
        refute reader.reload.alumni?
        assert_equal fresh.id, reader.participation.plan_run_id
        assert_nil reader.started_on
        assert_nil reader.participation.started_on
        assert_empty reader.checkoffs
        reader.mark_day_complete!(2)
      end
      before = [Bible270::Participation, Bible270::Checkoff, Bible270::Reader].map do |model|
        model.order(:id).map(&:attributes)
      end

      [@boss, @admin].each do |reader|
        parameters = { participation_id: old_memberships.fetch(reader.id).id, day: 0, start_date: '2030-01-01' }
        patch "#{mount}/admin/readers/#{reader.id}/through", params: parameters
        assert_redirected_to "#{mount}/admin"
        patch "#{mount}/admin/readers/#{reader.id}/start", params: parameters
        assert_redirected_to "#{mount}/admin"
        post "#{mount}/admin/readers/#{reader.id}/days/2", params: parameters
        assert_redirected_to "#{mount}/admin"
        assert_equal(before, [Bible270::Participation, Bible270::Checkoff, Bible270::Reader].map { |model| model.order(:id).map(&:attributes) })
      end
    end

    def test_deletion_rechecks_a_target_promoted_after_the_reader_was_loaded
      target_id = @reader.id
      finder = Bible270::Reader.method(:find_by)
      Bible270::Reader.stub(:find_by, ->(*args) {
        result = finder.call(*args)
        if result&.id == target_id
          Bible270::Reader.where(id: target_id).update_all(admin: true)
          refute result.admin?, 'simulate a target loaded before the promotion committed'
        end
        result
      }) do
        delete "#{mount}/admin/readers/#{target_id}"
      end

      assert_redirected_to "#{mount}/admin/readers/#{target_id}"
      assert Bible270::Reader.exists?(target_id)
      assert @reader.reload.admin?
      assert_match(%r{Only a site-admin}, flash[:alert])
    end

    def test_alumni_have_no_today_marker_from_their_frozen_calendar
      @reader.archive!

      assert @reader.calendar_day
      assert_nil @reader.today_day
      assert_equal Bible270.today, @reader.progress_today
    end

  private

    def mount = Bible270.config.mount_at.chomp('/')

    def reader(name, **attributes)
      email = "#{name.downcase}@safety.example.org"
      Bible270::Reader.create!(provider: 'email', uid: email, email: email, display_name: name, **attributes)
    end

    def sign_in_as(reader)
      _record, token = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{token}"
    end

    def restart_run
      Bible270::PlanRun.restart!(start_date: Bible270.today + 1, expected_run_id: @run.id)
    end
  end
end
