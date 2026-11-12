# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class AdminRunsTest < ActionDispatch::IntegrationTest
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
        assert_select 'input[type="checkbox"]', count: 0
        assert_select '> input[type="submit"][value="Start a new run"]'
      end
      refute_includes response.body, 'I understand that all current readers'
      assert_select 'script[data-b270-admin-confirmations]', count: 1
      assert_operator response.body.index('Start a new run'), :<, response.body.index('Show Alumni')
      refute_match(%r{delete reflections}i, response.body)
    end

    def test_alumni_use_a_collapsed_native_disclosure_with_the_list_ready_to_expand
      @reader.archive!
      get admin_path

      assert_response :success
      assert_select 'details#b270-alumni.b270-index:not([open])' do
        assert_select 'summary .b270-alumni-show', text: 'Show Alumni (1)'
        assert_select 'summary .b270-alumni-hide', text: 'Hide Alumni (1)'
        assert_select ".b270-li a[aria-label='#{@reader.display_name}']", count: 1
        assert_select 'form, input, button', count: 0
      end
      assert_select 'input[name="show_alumni"]', count: 0
      get admin_path, params: { show_alumni: '1' }
      assert_select 'details#b270-alumni:not([open])'
    end

    def test_role_and_alumni_badges_share_compact_styling_in_both_lists
      get admin_path

      assert_select '.b270-reader-theme .b270-admin-reader-details .name > .b270-badge.b270-reader-badge.b270-role-badge', text: 'Site-admin', count: 1
      assert_select '.b270-reader-theme .b270-admin-reader-details .name > .b270-badge.b270-reader-badge.b270-role-badge', text: 'Admin', count: 1
      assert_select '.b270-role-badge > span', text: 'Site-admin', count: 1
      assert_select '.b270-role-badge > span', text: 'Admin', count: 1
      @site_admin.archive!
      @admin.archive!
      @reader.archive!
      get admin_path

      assert_select '#b270-alumni .name > .b270-reader-badge.b270-role-badge', text: 'Site-admin', count: 1
      assert_select '#b270-alumni .name > .b270-reader-badge.b270-role-badge', text: 'Admin', count: 1
      assert_select '#b270-alumni .name > .b270-reader-badge:not(.b270-role-badge) > span', text: 'Alumni', count: 3
    end

    def test_empty_alumni_disclosure_still_has_an_informative_toggle
      get admin_path

      assert_select 'details#b270-alumni:not([open])' do
        assert_select 'summary .b270-alumni-show', text: 'Show Alumni (0)'
        assert_select '.b270-hint', text: 'No alumni yet.'
      end
    end

    def test_alumni_share_every_sort_and_layout_but_have_separate_report_data
      @reader.mark_through!(2)
      @reader.archive!
      other = create_reader('Zoe Alumni')
      other.mark_through!(4)
      other.archive!

      Bible270::AdminController::READER_SORT_OPTIONS.each_key do |sort|
        get admin_path, params: { sort: sort }

        assert_response :success
        assert_select '.b270-admin-reader-sort select[name="sort"] option[selected]' do |options|
          assert_equal sort, options.first['value']
        end
        assert_select 'details#b270-alumni:not([open])'
        assert_select '#b270-alumni .b270-li', count: 2
        assert_select '#b270-alumni .b270-reader-consistency', count: 2
        assert_select '#b270-alumni .b270-reader-activity', count: 2
        assert_select '#b270-alumni .b270-badge', text: 'Alumni', count: 2
        assert_select '.b270-consistency-explanation', count: sort == 'consistency' ? 1 : 0
        assert_select '#b270-reader-stats-dialog pre' do |tables|
          refute_includes tables.first.text, @reader.display_name
          refute_includes tables.first.text, other.display_name
          assert_includes tables.first.text, @admin.display_name
        end
        assert_select "#b270-alumni a[href='mailto:#{@reader.email}']" do |emails|
          assert_includes emails.first.parent.text.squish, '2/270 days · 8 days behind'
        end
        next unless %w[most_completed least_completed].include?(sort)

        names = css_select('#b270-alumni .name a').map(&:text)
        expected = sort == 'most_completed' ? [other.display_name, @reader.display_name] : [@reader.display_name, other.display_name]
        assert_equal expected, names
      end
      get admin_path, params: { sort: 'most_completed' }
      assert_select '.b270-admin-reader-sort input[name="show_alumni"]', count: 0
      assert_select 'details#b270-alumni:not([open])'
      assert_select '#b270-alumni .b270-li', count: 2
    end

    def test_active_counts_shared_calendars_and_everyone_broadcast_exclude_alumni
      @reader.update!(started_on: Bible270.today - 1)
      @reader.archive!
      alumni_admin = create_reader('Alumni Admin', admin: true)
      alumni_admin.archive!
      get admin_path

      assert_select '.lede', text: %r{2 readers taking part}
      assert_includes response.body, '2 readers following the shared calendar'
      assert_includes response.body, '2 active readers'
      assert_includes response.body, '3 admins'
      assert_includes response.body, 'including alumni admins'
      assert_includes response.body, 'Ordinary alumni do not receive broadcasts'
      deliveries = []
      Bible270::NoticeMailer.stub(:broadcast, ->(**arguments) {
        deliveries << arguments.fetch(:reader_id)
        Object.new.tap { |mail| mail.define_singleton_method(:deliver_now) { true } }
      }) do
        post "#{mount}/admin/broadcast", params: { subject: 'Hello', body: 'Welcome', audience: 'everyone' }
        assert_equal [@site_admin.id, @admin.id].sort, deliveries.sort
        deliveries.clear
        post "#{mount}/admin/broadcast", params: { subject: 'Hello admins', body: 'Welcome', audience: 'admins' }
        assert_equal [@site_admin.id, @admin.id, alumni_admin.id].sort, deliveries.sort
      end
    end

    def test_ordinary_admin_can_archive_and_reactivate_same_run_without_losing_progress_or_role
      @reader.update!(started_on: Bible270.today - 2)
      @reader.mark_through!(2)
      original_membership = @reader.participation.id
      change_status(@reader, 'alumni')

      assert_redirected_to reader_path(@reader)
      assert @reader.reload.alumni?
      assert_equal 2, @reader.days_completed
      change_status(@reader, 'active')
      assert_redirected_to reader_path(@reader)
      refute @reader.reload.alumni?
      assert_equal original_membership, @reader.participation.id
      assert_equal Bible270.today - 2, @reader.started_on
      assert_equal 2, @reader.days_completed
      change_status(@admin, 'alumni')
      assert @admin.reload.alumni?
      assert Bible270.config.admin?(@admin)
      get admin_path
      assert_response :success
    end

    def test_reactivation_in_a_new_run_starts_fresh_and_preserves_old_membership
      @reader.update!(started_on: Bible270.today - 4)
      @reader.mark_through!(3)
      old_membership = @reader.participation
      Bible270::PlanRun.restart!(start_date: Bible270.today + 1, expected_run_id: @run.id)
      get reader_path(@reader)
      assert_select '#b270-participation h2', text: 'Status: Alumni'
      assert_select '#b270-participation form[data-b270-admin-confirm]' do |forms|
        assert_includes forms.first['data-b270-admin-confirm'], 'joining a different run starts fresh progress'
      end
      assert_select '#b270-participation p', count: 0

      change_status(@reader, 'active')

      assert_redirected_to reader_path(@reader)
      refute @reader.reload.alumni?
      assert_nil @reader.started_on
      assert_equal 0, @reader.days_completed
      refute_equal old_membership.id, @reader.participation.id
      assert_equal 2, @reader.participations.count
      assert_equal Bible270.today - 4, old_membership.reload.frozen_start_date
      assert_operator old_membership.checkoffs.count, :>, 0
      assert_equal 2, @reader.participations.count
    end

    def test_invalid_and_stale_membership_forms_leave_membership_unchanged
      [nil, '', 'inactive', 'ADMIN'].each do |status|
        patch participation_path(@reader), params: { status: status, expected_run_id: @run.id }
        assert_redirected_to reader_path(@reader)
        assert flash[:alert].present?
        refute @reader.reload.alumni?
      end
      [nil, '', @run.id + 1].each do |id|
        patch participation_path(@reader), params: { status: 'alumni', expected_run_id: id }
        assert flash[:alert].present?
        refute @reader.reload.alumni?
      end
      Bible270::PlanRun.restart!(start_date: Bible270.today, expected_run_id: @run.id)
      patch participation_path(@reader), params: { status: 'active', expected_run_id: @run.id }
      assert flash[:alert].present?
      assert @reader.reload.alumni?
      assert_equal 1, @reader.participations.count
    end

    def test_alumni_progress_controls_are_read_only_but_profile_reflections_and_role_remain
      @reader.mark_through!(2)
      @reader.comments.create!(day: 1, body: 'Still visible')
      @reader.archive!
      get reader_path(@reader)

      assert_response :success
      assert_select '#b270-participation h2', text: 'Status: Alumni'
      assert_select "form[action='#{participation_path(@reader)}'][data-b270-admin-confirm]" do
        assert_select 'input[name="status"][value="active"]'
        assert_select "input[name='expected_run_id'][value='#{@run.id}']"
      end
      assert_select "form[action='#{reader_path(@reader)}/start']", count: 0
      assert_select "form[action='#{reader_path(@reader)}/through']", count: 0
      assert_select "form[action^='#{reader_path(@reader)}/days/']", count: 0
      assert_select '.b270-grid span', count: Bible270::Plan::DAYS
      assert_select "form[action='#{reader_path(@reader)}/profile']", count: 1
      assert_select '#b270-role', text: %r{Reader}
      assert_includes response.body, 'Still visible'
      assert_select "form[action='#{reader_path(@reader)}/role']", count: 0
      original_ids = @reader.checkoffs.pluck(:id)
      patch "#{reader_path(@reader)}/start", params: { start_date: Bible270.today.to_s }
      assert_redirected_to reader_path(@reader)
      assert_match(%r{read-only}, flash[:alert])
      patch "#{reader_path(@reader)}/through", params: { day: 0 }
      assert_redirected_to reader_path(@reader)
      assert_match(%r{read-only}, flash[:alert])
      post "#{reader_path(@reader)}/days/1"
      assert_redirected_to reader_path(@reader)
      assert_match(%r{read-only}, flash[:alert])
      assert_equal original_ids.sort, @reader.reload.checkoffs.pluck(:id).sort
      patch "#{reader_path(@reader)}/profile", params: { first_name: 'Updated', last_name: 'Alumnus', admin: '1', role: 'admin' }
      assert_redirected_to reader_path(@reader)
      assert_equal 'Updated Alumnus', @reader.reload.display_name
      refute @reader.admin?
    end

    def test_archived_progress_races_redirect_instead_of_raising
      find_reader = Bible270::Reader.method(:find_by)
      Bible270::Reader.stub(:find_by, ->(**attributes) {
        attributes[:id].to_s == @reader.id.to_s ? @reader : find_reader.call(**attributes)
      }) do
        @reader.stub(:mark_through!, ->(*) { raise Bible270::Participation::ArchivedProgress }) do
          patch "#{reader_path(@reader)}/through", params: { day: 2 }
        end
      end
      assert_redirected_to reader_path(@reader)
      assert_match(%r{read-only}, flash[:alert])
    end

    def test_history_uses_frozen_dates_and_one_grouped_completion_query_for_multiple_runs
      @reader.update!(started_on: Bible270.today - 4)
      @reader.mark_through!(2)
      first = @reader.participation
      Bible270::PlanRun.restart!(start_date: Bible270.today + 1, expected_run_id: @run.id)
      @reader.reload.activate!
      @reader.mark_through!(3)
      second_run = Bible270::PlanRun.current
      Bible270::PlanRun.restart!(start_date: Bible270.today + 30, expected_run_id: second_run.id)
      @reader.reload.activate!
      queries = []
      subscriber = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] }
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') { get reader_path(@reader) }

      assert_response :success
      assert_select '#b270-run-history tbody tr', count: 2
      assert_select '#b270-run-history td', text: '2/270'
      assert_select '#b270-run-history td', text: '3/270'
      assert_select '#b270-run-history td', text: first.reload.frozen_start_date.strftime('%b %-d, %Y')
      assert_includes css_select('#b270-run-history').first.text, (Bible270.today - 4).strftime('%b %-d, %Y')
      assert_equal(1, queries.count { |sql| sql.match?(%r{GROUP BY.*participation_id.*day}i) })
      assert_select '#b270-run-history form', count: 0
      assert_select '#b270-participation h2', text: 'Status: Active'
    end

    def test_delete_cannot_indirectly_revoke_admin_or_configured_privileges
      [@site_admin, @admin].each do |target|
        get reader_path(target)
        assert_select 'form[data-b270-remove-reader]', count: 0
        delete reader_path(target)
        assert_redirected_to reader_path(target)
        assert Bible270::Reader.exists?(target.id)
      end
      sign_in_as(@site_admin)
      get reader_path(@site_admin)
      assert_select '#b270-role h2', text: 'Role: Site-admin'
      assert_select '#b270-role p, #b270-role form', count: 0
      delete reader_path(@site_admin)
      assert Bible270::Reader.exists?(@site_admin.id)
      get reader_path(@admin)
      assert_select 'form[data-b270-remove-reader]', count: 1
      delete reader_path(@admin)
      assert_redirected_to admin_path
      refute Bible270::Reader.exists?(@admin.id)
    end

    def test_ordinary_admin_can_delete_a_reader_including_archived_history
      @reader.mark_through!(2)
      Bible270::PlanRun.restart!(start_date: Bible270.today, expected_run_id: @run.id)
      delete reader_path(@reader)

      assert_redirected_to admin_path
      refute Bible270::Reader.exists?(@reader.id)
      refute Bible270::Participation.exists?(reader_id: @reader.id)
      refute Bible270::Checkoff.exists?(reader_id: @reader.id)
    end

    def test_status_and_role_are_compact_rows_without_descriptive_text
      sign_in_as(@site_admin)
      get reader_path(@reader)

      assert_select '#b270-participation.b270-admin-control' do
        assert_select 'h2', text: 'Status: Active'
        assert_select 'form[data-b270-admin-confirm] button', text: 'Make alumni'
        assert_select 'p', count: 0
      end
      assert_select '#b270-role.b270-admin-control' do
        assert_select 'h2', text: 'Role: Reader'
        assert_select "form[action='#{reader_path(@reader)}/role'] button", text: 'Grant admin access'
        assert_select 'p', count: 0
      end
      @reader.update!(admin: true)
      @reader.archive!
      get reader_path(@reader)

      assert_select '#b270-participation h2', text: 'Status: Alumni'
      assert_select '#b270-participation button', text: 'Make active'
      assert_select '#b270-participation p', count: 0
      assert_select '#b270-role h2', text: 'Role: Admin'
      assert_select '#b270-role button', text: 'Remove admin access'
      assert_select '#b270-role p', count: 0
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
