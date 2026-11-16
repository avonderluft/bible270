# frozen_string_literal: true

require_relative 'support/admin_runs_test_case'

if RAILS_LOADED
  class AdminMembershipsTest < Bible270AdminRunsTestCase
    def test_only_alumni_rows_offer_quick_activation_with_the_current_run_and_detail_confirmation
      get admin_path
      assert_select '.b270-list .b270-admin-activate', count: 0

      @reader.archive!
      other = create_reader('Other Alumni')
      other.archive!
      get reader_path(@reader)
      confirmation = css_select('#b270-participation form').first['data-b270-admin-confirm']
      assert_equal 'Reactivate this reader in the current run? Same-run progress is preserved; joining a different run starts fresh progress and clears their personal start date. Past history is preserved.', confirmation
      fresh = Bible270::PlanRun.restart!(start_date: Bible270.today + 1, expected_run_id: @run.id)

      Bible270::AdminController::READER_SORT_OPTIONS.each_key do |sort|
        get admin_path, params: { sort: sort }

        assert_response :success
        assert_select '.b270-list .b270-admin-activate', count: 2
        [@reader, other].each do |reader|
          assert_select "#b270-alumni .stat form[action='#{participation_path(reader)}'][method='post']", count: 1 do |forms|
            assert_equal confirmation, forms.first['data-b270-admin-confirm']
            assert_select 'input[type="hidden"][name="_method"][value="patch"]'
            assert_select 'input[type="hidden"][name="status"][value="active"]'
            assert_select "input[type='hidden'][name='expected_run_id'][value='#{fresh.id}']"
            assert_select 'input[type="hidden"][name="return_to"][value="admin"]'
            assert_select "input[type='hidden'][name='sort'][value='#{sort}']"
            assert_select 'button.b270-btn.b270-admin-activate[type="submit"]', text: 'Make Active'
          end
        end
      end
      get admin_path, params: { sort: 'unknown' }
      assert_select '#b270-alumni input[name="sort"][value="first_name"]', count: 2
    end

    def test_quick_activation_in_the_same_run_preserves_progress_and_returns_to_the_chosen_sort
      @reader.update!(started_on: Bible270.today - 2)
      @reader.mark_through!(2)
      @reader.archive!
      membership = @reader.participation
      checkoffs = membership.checkoffs.order(:id).map(&:attributes)

      patch participation_path(@reader), params: quick_activation_params

      assert_redirected_to "#{admin_path}?sort=last_name"
      assert_equal 'Reader is active in the current run.', flash[:notice]
      refute @reader.reload.alumni?
      assert_equal membership.id, @reader.participation.id
      assert_equal Bible270.today - 2, @reader.started_on
      assert_equal 2, @reader.days_completed
      assert_equal checkoffs, @reader.checkoffs.order(:id).map(&:attributes)
      follow_redirect!
      assert_response :success
      assert_select 'option[value="last_name"][selected]'
      assert_select '#b270-alumni .b270-li', count: 0
      assert_select '.b270-list .b270-admin-activate', count: 0
      assert_select ".b270-list .name a[href='#{reader_path(@reader)}']", count: 1
    end

    def test_quick_activation_in_a_different_run_starts_fresh_and_preserves_history
      @reader.update!(started_on: Bible270.today - 4)
      @reader.mark_through!(3)
      reflection = @reader.comments.create!(day: 1, body: 'Past reflection')
      membership = @reader.participation
      fresh = Bible270::PlanRun.restart!(start_date: Bible270.today + 1, expected_run_id: @run.id)
      history = membership.reload.attributes
      checkoffs = membership.checkoffs.order(:id).map(&:attributes)

      patch participation_path(@reader), params: quick_activation_params.merge(expected_run_id: fresh.id)

      assert_redirected_to "#{admin_path}?sort=last_name"
      refute @reader.reload.alumni?
      assert_equal fresh.id, @reader.participation.plan_run_id
      refute_equal membership.id, @reader.participation.id
      assert_equal 2, @reader.participations.count
      assert_nil @reader.started_on
      assert_nil @reader.participation.started_on
      assert_equal 0, @reader.days_completed
      assert_empty @reader.checkoffs
      assert_equal history, membership.reload.attributes
      assert_equal checkoffs, membership.checkoffs.order(:id).map(&:attributes)
      assert_equal 'Past reflection', reflection.reload.body
    end

    def test_invalid_or_stale_quick_activation_is_a_noop_and_returns_to_the_list
      @reader.mark_through!(1)
      @reader.archive!
      before = membership_snapshot
      [quick_activation_params.merge(status: 'invalid'), quick_activation_params.except(:expected_run_id),
       quick_activation_params.merge(expected_run_id: ''), quick_activation_params.merge(expected_run_id: @run.id + 1)].each do |parameters|
        patch participation_path(@reader), params: parameters

        assert_redirected_to "#{admin_path}?sort=last_name"
        assert flash[:alert].present?
        assert_equal before, membership_snapshot
      end
      Bible270::PlanRun.restart!(start_date: Bible270.today + 1, expected_run_id: @run.id)
      before = membership_snapshot
      patch participation_path(@reader), params: quick_activation_params

      assert_redirected_to "#{admin_path}?sort=last_name"
      assert_match(%r{run changed}, flash[:alert])
      assert_equal before, membership_snapshot
      Bible270::PlanRun.stub(:current, @run) do
        patch participation_path(@reader), params: quick_activation_params
      end
      assert_redirected_to "#{admin_path}?sort=last_name"
      assert_match(%r{run changed}, flash[:alert])
      assert_equal before, membership_snapshot
    end

    def test_quick_activation_only_accepts_a_fixed_admin_destination_and_allowlisted_sort
      ['https://evil.example/admin', '//evil.example/admin', "#{admin_path}?sort=last_name", '/other'].each do |destination|
        @reader.archive!
        patch participation_path(@reader), params: quick_activation_params.merge(return_to: destination)

        assert_redirected_to reader_path(@reader)
        refute @reader.reload.alumni?
      end
      [nil, '', 'https://evil.example', '//evil.example', 'unknown'].each do |sort|
        @reader.archive!
        patch participation_path(@reader), params: quick_activation_params.merge(sort: sort)

        assert_redirected_to "#{admin_path}?sort=first_name"
        refute @reader.reload.alumni?
      end
    end

    def test_visitors_readers_and_admin_preview_cannot_quick_activate_alumni
      @reader.archive!
      before = membership_snapshot
      open_session do |visitor|
        visitor.patch participation_path(@reader), params: quick_activation_params
        assert_equal 404, visitor.response.status
      end
      assert_equal before, membership_snapshot
      sign_in_as(@reader)
      before = membership_snapshot
      patch participation_path(@reader), params: quick_activation_params
      assert_response :not_found
      assert_equal before, membership_snapshot

      [@admin, @site_admin].each do |admin|
        sign_in_as(admin)
        patch "#{admin_path}/view", params: { view: 'reader' }
        get admin_path
        assert_response :success
        assert_select '.b270-admin-activate', count: 0
        assert_select '#b270-active-readers, #b270-alumni, .b270-admin-reader-tools, #b270-reader-stats-dialog', count: 0
        before = membership_snapshot
        patch participation_path(@reader), params: quick_activation_params
        assert_response :not_found
        assert_equal before, membership_snapshot
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
  end
end
