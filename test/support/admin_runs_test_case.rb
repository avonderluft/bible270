# frozen_string_literal: true

require_relative '../test_helper'

if RAILS_LOADED
  class Bible270AdminRunsTestCase < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_config = %i[
        admin_emails admin_resolver current_reader_resolver registration_notice_deliver_later
        start_date allow_reader_start_date
      ].to_h { |key| [key, Bible270.config.public_send(key)] }
      Bible270.config.admin_resolver = nil
      Bible270.config.current_reader_resolver = nil
      Bible270.config.registration_notice_deliver_later = false
      Bible270.config.start_date = Bible270.today - 9
      Bible270.config.allow_reader_start_date = true
      @sequence = 0
      @site_admin = create_reader('Configured Boss')
      @admin = create_reader('Ordinary Admin', admin: true)
      @reader = create_reader('Active Reader')
      Bible270.config.admin_emails = [@site_admin.email]
      @run = Bible270::PlanRun.current
      sign_in_as(@admin)
    end

    def teardown
      @previous_config&.each { |key, value| Bible270.config.public_send("#{key}=", value) }
    end

  private

    def assert_site_admin_survives_restarts
      sign_in_as(@site_admin)
      2.times do
        run = Bible270::PlanRun.current
        post restart_path, params: restart_params.merge(expected_run_id: run.id)

        assert_redirected_to admin_path
        refute @site_admin.reload.alumni?
        assert_nil @site_admin.started_on
        assert_nil @site_admin.participation.started_on
        assert_empty @site_admin.checkoffs
        assert Bible270.config.site_admin?(@site_admin)
        assert Bible270.config.admin?(@site_admin)
        refute @site_admin.admin?, 'configured access must not depend on a stored admin grant'
        follow_redirect!
        assert_response :success
        get reader_path(@site_admin)
        assert_select '#b270-role', text: %r{Site-admin}
        assert_select "form[action='#{participation_path(@site_admin)}'] input[name='status'][value='alumni']"

        change_status(@site_admin, 'alumni')
        assert_redirected_to reader_path(@site_admin)
        assert @site_admin.reload.alumni?
        get reader_path(@site_admin)
        assert_select "form[action='#{participation_path(@site_admin)}'] input[name='status'][value='active']"

        change_status(@site_admin, 'active')
        assert_redirected_to reader_path(@site_admin)
        refute @site_admin.reload.alumni?
        assert_equal Bible270::PlanRun.current.id, @site_admin.participation.plan_run_id
        assert_equal 0, @site_admin.days_completed
        follow_redirect!
        assert_select "form[action='#{participation_path(@site_admin)}'] input[name='status'][value='alumni']"

        change_status(@site_admin, 'alumni')
        assert_redirected_to reader_path(@site_admin)
        assert @site_admin.reload.alumni?
        assert Bible270.config.site_admin?(@site_admin)
        get admin_path
        assert_response :success
      end
      patch "#{reader_path(@reader)}/role", params: { role: 'admin' }
      assert_redirected_to reader_path(@reader)
      assert @reader.reload.admin?, 'an alumni site-admin must retain role-management privileges'
    end

    def mount = Bible270.config.mount_at.chomp('/')
    def admin_path = "#{mount}/admin"
    def restart_path = "#{admin_path}/restart"
    def reader_path(reader) = "#{admin_path}/readers/#{reader.id}"
    def participation_path(reader) = "#{reader_path(reader)}/participation"

    def restart_params
      { start_date: (Bible270.today + 1).iso8601, expected_run_id: @run.id, confirm_restart: '1' }
    end

    def quick_activation_params
      { status: 'active', expected_run_id: @run.id, return_to: 'admin', sort: 'last_name' }
    end

    def membership_snapshot
      [Bible270::PlanRun, Bible270::Reader, Bible270::Participation, Bible270::Checkoff].map do |model|
        model.order(:id).map(&:attributes)
      end
    end

    def change_status(reader, status)
      patch participation_path(reader), params: { status: status, expected_run_id: Bible270::PlanRun.current.id }
    end

    def create_reader(name, **attributes)
      @sequence += 1
      email = "admin-runs-#{@sequence}@example.org"
      Bible270::Reader.create!(provider: 'email', uid: email, email: email, display_name: name, **attributes)
    end

    def sign_in_as(reader)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"
    end
  end
end
