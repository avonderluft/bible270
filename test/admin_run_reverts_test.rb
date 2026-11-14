# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class AdminRunRevertsTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_config = %i[
        admin_emails admin_resolver current_reader_resolver registration_notice_deliver_later
        start_date allow_reader_start_date enrollment_open mention_notifications
      ].to_h { |key| [key, Bible270.config.public_send(key)] }
      Bible270.config.admin_resolver = nil
      Bible270.config.current_reader_resolver = nil
      Bible270.config.registration_notice_deliver_later = false
      Bible270.config.start_date = Bible270.today - 9
      Bible270.config.allow_reader_start_date = true
      Bible270.config.enrollment_open = true
      Bible270.config.mention_notifications = false
      @sequence = 0
      @site_admin = create_reader('Configured Boss')
      @admin = create_reader('Ordinary Admin', admin: true)
      @reader = create_reader('Reader')
      Bible270.config.admin_emails = [@site_admin.email]
      @run = Bible270::PlanRun.current
      sign_in_as(@admin)
    end

    def teardown
      @previous_config&.each { |key, value| Bible270.config.public_send("#{key}=", value) }
    end

    def test_revert_button_tops_the_panel_without_a_heading_or_checkbox_and_keeps_native_confirmation
      get admin_path
      assert_response :success
      assert_select "form[action='#{revert_path}']", count: 0
      fresh = restart_run

      get admin_path

      assert_response :success
      assert_select ".b270-panel > form.b270-revert-form:first-child[action='#{revert_path}'][method='post'][data-b270-admin-confirm]", count: 1 do |forms|
        assert_includes forms.first['data-b270-admin-confirm'], 'restored for everyone, including admins'
        assert_includes forms.first['data-b270-admin-confirm'], 'Readers who joined only the newer run will become alumni'
        assert_select "input[type='hidden'][name='expected_run_id'][value='#{fresh.id}']"
        assert_select 'input[type="hidden"][name="confirm_revert"][value="1"]'
        assert_select 'input[type="checkbox"], label', count: 0
        assert_select 'input[type="submit"][value="Revert to previous run"]', count: 1
      end
      assert_select 'h2', text: 'Revert to previous run', count: 0
      refute_includes response.body, 'Restore the previous run and its reader statuses.'
      assert_select 'script[data-b270-admin-confirmations]', count: 1
      post revert_path, params: revert_params
      follow_redirect!
      assert_response :success
      assert_select "form[action='#{revert_path}']", count: 0
    end

    def test_legacy_runs_hide_the_form_and_reject_a_forged_revert
      fresh = restart_run
      fresh.update!(restart_snapshot: nil)
      get admin_path
      assert_response :success
      assert_select "form[action='#{revert_path}']", count: 0
      before = database_snapshot

      post revert_path, params: revert_params

      assert_redirected_to admin_path
      assert flash[:alert].present?
      assert_equal before, database_snapshot
    end

    def test_visitors_and_ordinary_readers_cannot_revert
      restart_run
      delete "#{mount}/sign_out"
      before = database_snapshot

      post revert_path, params: revert_params

      assert_response :not_found
      assert_equal before, database_snapshot
      sign_in_as(@reader)
      before = database_snapshot
      post revert_path, params: revert_params
      assert_response :not_found
      assert_equal before, database_snapshot
    end

    def test_admin_reader_view_hides_and_denies_revert_until_full_admin_view_is_restored
      restart_run
      patch "#{admin_path}/view", params: { view: 'reader' }
      assert_response :see_other
      get admin_path
      assert_response :success
      assert_select "form[action='#{revert_path}']", count: 0
      before = database_snapshot

      post revert_path, params: revert_params

      assert_response :not_found
      assert_equal before, database_snapshot
      patch "#{admin_path}/view", params: { view: 'admin' }
      assert_response :see_other
      post revert_path, params: revert_params
      assert_redirected_to admin_path
      assert_equal @run, Bible270::PlanRun.current
    end

    def test_missing_confirmation_and_missing_or_stale_run_ids_are_noops
      fresh = restart_run
      parameters = revert_params
      before = database_snapshot
      [parameters.except(:confirm_revert), parameters.merge(confirm_revert: '0'),
       parameters.merge(confirm_revert: 'true'), parameters.except(:expected_run_id),
       parameters.merge(expected_run_id: ''), parameters.merge(expected_run_id: @run.id)].each do |params|
        post revert_path, params: params

        assert_redirected_to admin_path
        assert flash[:alert].present?
        assert_equal before, database_snapshot
      end
      post revert_path, params: parameters
      assert_redirected_to admin_path
      restored = database_snapshot
      post revert_path, params: parameters
      assert_redirected_to admin_path
      assert flash[:alert].present?
      assert_equal restored, database_snapshot
      post revert_path, params: { confirm_revert: '1', expected_run_id: @run.id }
      assert_redirected_to admin_path
      assert flash[:alert].present?
      assert_equal restored, database_snapshot
      assert fresh.reload.reverted_at
    end

    def test_an_ordinary_admin_can_revert_without_losing_content_or_roles
      refute Bible270.config.site_admin?(@admin)
      @reader.update!(started_on: Bible270.today - 3)
      @reader.mark_day_complete!(1)
      @admin.mark_day_complete!(1)
      @reader.comments.create!(day: 1, body: 'Original reflection')
      Bible270::Setting.close_enrollment!
      original_settings = Bible270::Setting.order(:key).pluck(:key, :value)
      fresh = restart_run
      refute @admin.reload.alumni?
      assert_equal fresh.id, @admin.participation.plan_run_id
      assert_equal 0, @admin.days_completed
      @reader.reload.activate!
      @reader.mark_day_complete!(2)
      @reader.comments.create!(day: 2, body: 'Newer reflection')
      memberships = Bible270::Participation.order(:id).pluck(:id)
      content = [Bible270::Checkoff, Bible270::Comment].map { |model| model.order(:id).map(&:attributes) }
      roles = Bible270::Reader.order(:id).pluck(:id, :admin)

      post revert_path, params: revert_params

      assert_redirected_to admin_path
      assert flash[:notice].present?
      assert_equal @run, Bible270::PlanRun.current
      assert fresh.reload.reverted_at
      assert_equal 2, Bible270::PlanRun.count
      assert_equal memberships, Bible270::Participation.order(:id).pluck(:id)
      assert_equal(content, [Bible270::Checkoff, Bible270::Comment].map { |model| model.order(:id).map(&:attributes) })
      assert_equal roles, Bible270::Reader.order(:id).pluck(:id, :admin)
      assert_equal original_settings, Bible270::Setting.order(:key).pluck(:key, :value)
      assert Bible270::Setting.enrollment_closed?
      assert_equal Bible270.today - 3, @reader.reload.started_on
      assert_equal 3, Bible270::Reader.active.count
      refute @admin.reload.alumni?
      assert Bible270.config.admin?(@admin)
      follow_redirect!
      assert_response :success
      assert_select '.lede', text: %r{3 readers taking part}
      get reader_path(@reader)
      assert_response :success
      assert_select '#b270-participation h2', text: 'Status: Active'
      assert_select '#b270-run-history tbody tr', count: 1
      assert_select '#b270-run-history td', text: '1/270'
      assert_select '#b270-run-history td', text: "Run #{fresh.id} (reverted)", count: 1
      assert_select '#b270-run-history form', count: 0
      assert_includes response.body, 'Original reflection'
      assert_includes response.body, 'Newer reflection'
    end

    def test_revert_restores_original_active_and_alumni_statuses_even_for_admins_and_site_admins
      active_admin = create_reader('Originally Active Admin', admin: true)
      [@admin, @site_admin, @reader].each do |reader|
        reader.update!(started_on: Bible270.today - 4)
        reader.mark_day_complete!(1)
        reader.archive!
      end
      original_memberships = [@admin, @site_admin, @reader, active_admin].to_h do |reader|
        [reader.id, reader.participation.attributes.except('updated_at')]
      end
      original_dates = Bible270::Reader.order(:id).pluck(:id, :started_on)
      checkoffs = Bible270::Checkoff.order(:id).map(&:attributes)
      fresh = restart_run
      [@admin, @site_admin, active_admin].each do |reader|
        refute reader.reload.alumni?
        assert_equal fresh.id, reader.participation.plan_run_id
        assert_equal 0, reader.days_completed
        assert_nil reader.started_on
      end
      fresh_memberships = fresh.participations.order(:id).pluck(:id)
      get admin_path
      assert_select "form[action='#{revert_path}']" do |forms|
        refute_includes forms.first['data-b270-admin-confirm'], 'Admins and Site-admins will be active'
      end

      post revert_path, params: revert_params

      assert_redirected_to admin_path
      refute_match(%r{Admins and Site-admins are active}, flash[:notice])
      assert_equal @run, Bible270::PlanRun.current
      assert_equal [active_admin.id], Bible270::Reader.active.pluck(:id)
      [@admin, @site_admin, @reader, active_admin].each do |reader|
        reader.reload
        original = original_memberships.fetch(reader.id)
        # Membership is restored, but links invalidated by archiving stay invalid.
        generation = original.fetch('progress_sync_generation') + (original.fetch('active') ? 1 : 0)
        assert_equal original.merge('progress_sync_generation' => generation), reader.participation.attributes.except('updated_at')
      end
      [@admin, @site_admin, @reader].each { |reader| assert reader.alumni? }
      assert Bible270.config.admin?(@admin)
      assert Bible270.config.site_admin?(@site_admin)
      assert_equal original_dates, Bible270::Reader.order(:id).pluck(:id, :started_on)
      assert_equal checkoffs, Bible270::Checkoff.order(:id).map(&:attributes)
      assert_equal fresh_memberships, fresh.participations.order(:id).pluck(:id)
      assert_empty fresh.participations.where(active: true)
      follow_redirect!
      assert_response :success
      assert_select '.lede', text: %r{1 reader taking part}
    end

    def test_roles_granted_in_the_new_run_survive_revert_including_a_newer_only_admin
      original_alumni = create_reader('Originally Alumni Reader')
      original_alumni.update!(started_on: Bible270.today - 3)
      original_alumni.mark_day_complete!(1)
      original_alumni.archive!
      alumni_membership = original_alumni.participation.attributes
      alumni_checkoffs = original_alumni.checkoffs.order(:id).map(&:attributes)
      restart_run
      newcomer = create_reader('Newly Granted Admin')
      newcomer.update!(started_on: Bible270.today - 2)
      newcomer.mark_day_complete!(2)
      newcomer_membership = newcomer.participation
      newcomer_checkoffs = newcomer.checkoffs.order(:id).map(&:attributes)
      sign_in_as(@site_admin)
      [@reader, original_alumni, newcomer].each do |target|
        refute target.admin?
        patch "#{reader_path(target)}/role", params: { role: 'admin' }
        assert_redirected_to reader_path(target)
        assert target.reload.admin?
      end
      sign_in_as(newcomer)
      refute Bible270.config.site_admin?(newcomer)

      post revert_path, params: revert_params

      assert_redirected_to admin_path
      assert_equal @run, Bible270::PlanRun.current
      assert @reader.reload.admin?
      refute @reader.alumni?
      assert original_alumni.reload.admin?
      assert original_alumni.alumni?
      assert_equal alumni_membership, original_alumni.participation.attributes
      assert_equal alumni_checkoffs, original_alumni.checkoffs.order(:id).map(&:attributes)
      assert_equal Bible270.today - 3, original_alumni.started_on
      assert newcomer.reload.admin?
      assert newcomer.alumni?
      assert_equal newcomer_membership, newcomer.participation
      refute_equal @run.id, newcomer.participation.plan_run_id
      assert_equal 1, newcomer.participations.count
      refute newcomer.participations.exists?(plan_run: @run)
      assert_equal 1, newcomer.days_completed
      assert_equal Bible270.today - 2, newcomer.started_on
      assert_equal newcomer_checkoffs, newcomer.checkoffs.order(:id).map(&:attributes)
      follow_redirect!
      assert_response :success
      assert_select "form[action='#{revert_path}']", count: 0
    end

    def test_newer_only_readers_are_alumni_with_retained_read_only_progress_and_history
      fresh = restart_run
      newcomer = create_reader('Newer Only')
      newcomer.mark_day_complete!(2)
      newcomer.comments.create!(day: 2, body: 'Newer-only reflection')
      membership = newcomer.participation
      checkoffs = membership.checkoffs.order(:id).map(&:attributes)
      post revert_path, params: revert_params

      get reader_path(newcomer)

      assert_response :success
      assert newcomer.reload.alumni?
      assert_equal membership, newcomer.participation
      assert_equal fresh, membership.reload.plan_run
      assert_equal 1, newcomer.days_completed
      assert_equal 1, newcomer.participations.count
      assert_select '#b270-participation h2', text: 'Status: Alumni'
      assert_select '#b270-run-history tbody tr', count: 1
      assert_select '#b270-run-history td', text: '1/270'
      assert_select '#b270-run-history form', count: 0
      assert_select "form[action='#{reader_path(newcomer)}/start']", count: 0
      assert_select "form[action='#{reader_path(newcomer)}/through']", count: 0
      assert_select "form[action^='#{reader_path(newcomer)}/days/']", count: 0
      assert_includes response.body, 'Newer-only reflection'
      patch "#{reader_path(newcomer)}/through", params: { day: 0, participation_id: membership.id }
      assert_redirected_to reader_path(newcomer)
      assert_match(%r{read-only}, flash[:alert])
      post "#{reader_path(newcomer)}/days/2", params: { participation_id: membership.id }
      assert_redirected_to reader_path(newcomer)
      assert_match(%r{read-only}, flash[:alert])
      assert_equal checkoffs, membership.checkoffs.order(:id).map(&:attributes)
      get admin_path
      assert_select '.lede', text: %r{3 readers taking part}
      assert_select "#b270-alumni a[href='#{reader_path(newcomer)}']", minimum: 1
    end

    def test_reader_facing_html_and_turbo_forms_from_the_reverted_run_cannot_write
      @reader.mark_day_complete!(1)
      fresh = restart_run
      @reader.reload.activate!
      @reader.mark_day_complete!(1)
      newer_membership = @reader.participation
      sign_in_as(@reader)
      get "#{mount}/day/1"
      assert_response :success
      assert_select "form[data-b270-checkoff] input[name='participation_id'][value='#{newer_membership.id}']", minimum: 1
      Bible270::PlanRun.revert!(expected_run_id: fresh.id)
      before = database_snapshot

      [{}, { 'Accept' => 'text/vnd.turbo-stream.html' }].each do |headers|
        [[1, '0'], [3, '1']].each do |day, checked|
          post "#{mount}/day/#{day}/toggle/nt/0",
               params: { participation_id: newer_membership.id, checked: checked }, headers: headers

          if headers.empty?
            assert_redirected_to "#{mount}/day/#{day}"
            assert_match(%r{run changed}, flash[:alert])
          else
            assert_response :conflict
          end
          assert_equal before, database_snapshot
        end
      end
    end

    def test_enrollment_changes_revalidate_the_run_but_legacy_forms_need_no_expected_id
      Bible270::Setting.close_enrollment!
      fresh = restart_run
      Bible270::PlanRun.revert!(expected_run_id: fresh.id)
      before = database_snapshot

      Bible270::PlanRun.stub(:current, fresh) do
        patch "#{admin_path}/enrollment", params: { state: 'open' }
      end

      assert_redirected_to admin_path
      assert flash[:alert].present?
      assert_equal before, database_snapshot
      assert Bible270::Setting.enrollment_closed?
      patch "#{admin_path}/enrollment", params: { state: 'open' }
      assert_redirected_to admin_path
      assert flash[:notice].present?
      refute Bible270::Setting.enrollment_closed?
    end

    def test_newer_run_forms_are_stale_after_revert_but_restored_membership_writes_work
      old_membership = @reader.participation
      @reader.mark_day_complete!(1)
      fresh = restart_run
      @reader.reload.activate!
      @reader.mark_day_complete!(2)
      newer_membership = @reader.participation
      newer_checkoffs = newer_membership.checkoffs.order(:id).map(&:attributes)
      post revert_path, params: revert_params
      before = database_snapshot
      parameters = { participation_id: newer_membership.id, day: 0, start_date: '2030-01-01' }

      patch "#{reader_path(@reader)}/start", params: parameters
      assert_redirected_to admin_path
      patch "#{reader_path(@reader)}/through", params: parameters
      assert_redirected_to admin_path
      post "#{reader_path(@reader)}/days/1", params: parameters
      assert_redirected_to admin_path
      patch "#{admin_path}/run-start", params: { expected_run_id: fresh.id, start_date: '2030-01-01' }
      assert_redirected_to admin_path
      delete "#{admin_path}/run-start", params: { expected_run_id: fresh.id }
      assert_redirected_to admin_path
      patch "#{reader_path(@reader)}/participation", params: { expected_run_id: fresh.id, status: 'alumni' }
      assert_redirected_to reader_path(@reader)
      assert flash[:alert].present?
      assert_equal before, database_snapshot

      post "#{reader_path(@reader)}/days/3", params: { participation_id: old_membership.id }

      assert_redirected_to "#{reader_path(@reader)}#day-3"
      assert_equal [1, 3], @reader.reload.checkoffs.distinct.order(:day).pluck(:day)
      assert_equal newer_checkoffs, newer_membership.checkoffs.order(:id).map(&:attributes)
    end

  private

    def mount = Bible270.config.mount_at.chomp('/')
    def admin_path = "#{mount}/admin"
    def revert_path = "#{admin_path}/revert"
    def reader_path(reader) = "#{admin_path}/readers/#{reader.id}"

    def restart_run
      Bible270::PlanRun.restart!(start_date: Bible270.today + 1, expected_run_id: Bible270::PlanRun.current.id)
    end

    def revert_params
      { confirm_revert: '1', expected_run_id: Bible270::PlanRun.current.id }
    end

    def create_reader(name, **attributes)
      @sequence += 1
      email = "admin-reverts-#{@sequence}@example.org"
      Bible270::Reader.create!(provider: 'email', uid: email, email: email, display_name: name, **attributes)
    end

    def sign_in_as(reader)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"
    end

    def database_snapshot
      [Bible270::PlanRun, Bible270::Participation, Bible270::Reader, Bible270::Checkoff,
       Bible270::Comment, Bible270::Setting].map { |model| model.order(:id).map(&:attributes) }
    end
  end
end
