# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class AlumniAccessTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      Bible270::Like.delete_all
      @previous_config = %i[
        admin_emails admin_resolver current_reader_resolver start_date allow_reader_start_date
        mention_notifications registration_notice_emails registration_notice_deliver_later
        mailer_from mailer_host daily_reminders
      ].to_h { |key| [key, Bible270.config.public_send(key)] }
      Bible270.config.admin_emails = []
      Bible270.config.admin_resolver = nil
      Bible270.config.current_reader_resolver = nil
      Bible270.config.start_date = Bible270.today - 9
      Bible270.config.allow_reader_start_date = true
      Bible270.config.mention_notifications = false
      Bible270.config.registration_notice_emails = []
      Bible270.config.registration_notice_deliver_later = false
      Bible270.config.mailer_from = 'no-reply@example.org'
      Bible270.config.mailer_host = nil
      Bible270.config.daily_reminders = false
      @site_admin = create_reader('Boss', 'boss@example.org')
      @reader = create_reader('Alumni', 'alumni@example.org')
      @other = create_reader('Active', 'active@example.org')
      Bible270.config.admin_emails = [@site_admin.email]
      ActionMailer::Base.deliveries.clear
    end

    def teardown
      @previous_config&.each { |key, value| Bible270.config.public_send("#{key}=", value) }
      ActionMailer::Base.deliveries.clear
    end

    def test_alumni_can_sign_in_and_view_only_active_readers_in_community
      @reader.archive!
      before = progress_snapshot
      sign_in_as(@reader)

      get "#{mount}/community"

      assert_response :success
      assert_equal Bible270::Reader.active.pluck(:id).sort, community_reader_ids
      assert_select ".b270-list a[href='#{mount}/readers/#{@reader.id}']", count: 0
      assert_select "a[href='#{mount}/profile']"
      assert @reader.reload.alumni?
      assert_equal before, progress_snapshot
    end

    def test_alumni_can_view_the_new_group_without_being_enrolled_in_it
      restart_run!
      newcomer = create_reader('Newcomer', 'newcomer@example.org')
      before = progress_snapshot
      sign_in_as(@reader)

      get "#{mount}/community"

      assert_response :success
      assert_equal [@site_admin.id, newcomer.id].sort, community_reader_ids
      assert @reader.reload.alumni?
      assert_equal before, progress_snapshot
      refute @reader.participations.exists?(plan_run: Bible270::PlanRun.current)
    end

    def test_alumni_day_page_has_no_checkoff_forms_but_has_a_reflection_composer
      @reader.mark_day_complete!(1)
      @reader.archive!
      sign_in_as(@reader)
      before = progress_snapshot

      get "#{mount}/day/1"

      assert_response :success
      assert_select 'form[data-b270-checkoff]', count: 0
      assert_select "form[action*='/toggle/']", count: 0
      assert_select '#reading_1_nt.done'
      assert_select "form[action='#{mount}/day/1/comments'] textarea[name='comment[body]']"
      assert_equal before, progress_snapshot
    end

    def test_alumni_can_post_reflections_replies_and_likes_over_html_without_reactivation
      assert_alumni_can_participate(headers: {})
    end

    def test_alumni_can_post_reflections_replies_and_likes_over_turbo_without_reactivation
      assert_alumni_can_participate(headers: turbo_stream_headers)
    end

    def test_old_visible_reflections_and_replies_remain_accessible_to_the_new_active_group
      thought = @reader.comments.create!(day: 1, body: 'A reflection from the previous run')
      reply = @other.comments.create!(day: 1, body: 'An old reply worth preserving', parent: thought)
      hidden = @reader.comments.create!(day: 1, body: 'Hidden old reflection', approved: false)
      restart_run!
      newcomer = create_reader('Newcomer', 'newcomer@example.org')
      sign_in_as(newcomer)

      ["#{mount}/day/1", "#{mount}/reflections", "#{mount}/readers/#{@reader.id}"].each do |path|
        get path

        assert_response :success
        assert_select "#comment-#{thought.id}", text: %r{A reflection from the previous run}
        assert_select "#comment-#{reply.id}", text: %r{An old reply worth preserving}
        assert_select "#comment-#{hidden.id}", count: 0
      end
      get "#{mount}/reflections", params: { reader_id: @reader.id }
      assert_response :success
      assert_select "#comment-#{thought.id}"
      post "#{mount}/comments/#{thought.id}/like", params: { liked: '1' }
      assert_response :redirect
      assert thought.reload.liked_by?(newcomer)
      assert @reader.reload.alumni?
    end

    def test_alumni_can_still_read_their_archived_progress
      @reader.mark_day_complete!(1)
      @reader.archive!
      sign_in_as(@reader)
      before = progress_snapshot

      get "#{mount}/progress"

      assert_response :success
      assert_select '.b270-bignum .n', text: '1'
      assert_select "form[action*='/toggle/']", count: 0
      get "#{mount}/readers/#{@reader.id}"
      assert_response :success
      assert_includes response.body, '1 of 270 days complete'
      assert_select 'h1 > .b270-badge.b270-reader-badge > span', text: 'Alumni', count: 1
      assert_select "form[action*='/toggle/']", count: 0
      assert_equal 1, @reader.reload_progress.days_completed
      assert_equal before, progress_snapshot
    end

    def test_alumni_checkoff_attempts_over_html_are_blocked_without_progress_mutation
      assert_alumni_checkoffs_blocked(headers: {})
    end

    def test_alumni_checkoff_attempts_over_turbo_are_blocked_without_progress_mutation
      assert_alumni_checkoffs_blocked(headers: turbo_stream_headers)
    end

    def test_every_active_checkoff_form_identifies_the_current_participation
      sign_in_as(@reader)
      get "#{mount}/day/1"

      assert_response :success
      forms = css_select('form[data-b270-checkoff="true"]')
      assert_equal Bible270::Plan.total_parts(1), forms.size
      forms.each do |form|
        fields = form.css('input[type="hidden"][name="participation_id"]')
        assert_equal 1, fields.size
        assert_equal @reader.participation.id.to_s, fields.first['value']
      end
    end

    def test_stale_html_checkoff_forms_after_restart_and_reactivation_redirect_without_mutation
      assert_stale_forms_rejected(headers: {})
    end

    def test_stale_turbo_checkoff_forms_after_restart_and_reactivation_return_conflict_without_mutation
      assert_stale_forms_rejected(headers: turbo_stream_headers)
    end

    def test_restart_automatically_enrolls_admins_fresh_and_reactivation_preserves_their_history
      @reader.update!(started_on: Bible270.today - 4, admin: true)
      @reader.mark_day_complete!(1)
      old_membership = @reader.participation
      old_checkoffs = old_membership.checkoffs.order(:id).map(&:attributes)
      restart_run!
      archived_membership = old_membership.reload.attributes
      refute @reader.alumni?
      assert_equal Bible270::PlanRun.current.id, @reader.participation.plan_run_id
      assert_nil @reader.started_on
      assert_nil @reader.participation.started_on
      assert_equal 0, @reader.days_completed
      assert_empty @reader.checkoffs
      fresh_membership_id = @reader.participation.id

      reactivate_reader!

      refute @reader.alumni?
      assert_equal fresh_membership_id, @reader.participation.id
      assert @reader.admin?
      refute Bible270.config.site_admin?(@reader)
      refute_equal old_membership.id, @reader.participation.id
      assert_equal Bible270::PlanRun.current.id, @reader.participation.plan_run_id
      assert_equal 2, @reader.participations.count
      assert_nil @reader.started_on
      assert_nil @reader.participation.started_on
      assert_equal 0, @reader.days_completed
      assert_empty @reader.checkoffs
      assert_equal archived_membership, old_membership.reload.attributes
      assert_equal old_checkoffs, old_membership.checkoffs.order(:id).map(&:attributes)
      assert_equal Bible270.today - 4, old_membership.frozen_start_date
    end

    def test_same_day_checkoffs_read_and_delete_only_the_new_membership
      @reader.mark_day_complete!(1)
      old_membership = @reader.participation
      old_checkoffs = old_membership.checkoffs.order(:id).map(&:attributes)
      restart_run!
      reactivate_reader!
      sign_in_as(@reader)
      membership_id = @reader.participation.id

      get "#{mount}/day/1"
      assert_response :success
      assert_select '#reading_1_nt.done', count: 0
      assert_select "form[action='#{mount}/day/1/toggle/nt/0'] input[name='checked'][value='1']"
      assert_equal 0, @reader.reload_progress.checked_count(1)

      # A legacy toggle must create a fresh checkoff, not find and remove the old one.
      post "#{mount}/day/1/toggle/nt/0", params: { participation_id: membership_id }
      assert_response :redirect
      assert_equal 1, @reader.reload_progress.checked_count(1)
      fresh_checkoff = @reader.checkoffs.find_by!(day: 1, track: 'nt', part: 0)
      assert_equal membership_id, fresh_checkoff.participation_id
      assert_equal old_checkoffs, old_membership.checkoffs.order(:id).map(&:attributes)

      get "#{mount}/day/1"
      assert_select '#reading_1_nt.done'
      assert_select "form[action='#{mount}/day/1/toggle/nt/0'] input[name='checked'][value='0']"
      post "#{mount}/day/1/toggle/nt/0",
           params: { participation_id: membership_id, checked: '0' }, headers: turbo_stream_headers
      assert_response :success
      refute Bible270::Checkoff.exists?(fresh_checkoff.id)
      assert_equal 0, @reader.reload_progress.checked_count(1)
      assert_equal old_checkoffs, old_membership.checkoffs.order(:id).map(&:attributes)

      @reader.mark_day_complete!(1)
      assert_equal 1, @reader.reload_progress.days_completed
      assert_equal Bible270::Plan.total_parts(1) * 2, @reader.all_checkoffs.count
      assert_equal old_checkoffs, old_membership.checkoffs.order(:id).map(&:attributes)
    end

    def test_configured_site_admin_and_ui_admin_roles_are_independent_of_alumni_status
      @reader.archive!
      @site_admin.archive!
      before = progress_snapshot
      admin = admin_browser
      assert Bible270.config.site_admin?(@site_admin.reload)
      refute @site_admin.admin?

      admin.patch "#{mount}/admin/readers/#{@reader.id}/role", params: { role: 'admin' }
      admin.assert_response :see_other
      assert @reader.reload.admin?
      refute Bible270.config.site_admin?(@reader)
      assert @reader.alumni?
      assert_equal before, progress_snapshot
      sign_in_as(@reader)
      get "#{mount}/admin"
      assert_response :success
      patch "#{mount}/admin/readers/#{@site_admin.id}/role", params: { role: 'reader' }
      assert_response :not_found
      assert Bible270.config.site_admin?(@site_admin.reload)

      admin.patch "#{mount}/admin/readers/#{@reader.id}/role", params: { role: 'reader' }
      admin.assert_response :see_other
      refute @reader.reload.admin?
      assert @reader.alumni?
      get "#{mount}/admin"
      assert_response :not_found
      get "#{mount}/community"
      assert_response :success
      assert_equal before, progress_snapshot
    end

    def test_daily_reminder_rechecks_alumni_status_when_manually_called_after_archive
      Bible270.config.daily_reminders = true
      @reader.update!(daily_reminders: true)
      assert_includes Bible270::Reader.daily_reminder_recipients(on: Bible270.today), @reader
      assert_equal [@reader.email], Bible270::NoticeMailer.daily_reminder(reader_id: @reader.id, day: 1).to
      queued_notice = Bible270::NoticeMailer.daily_reminder(reader_id: @reader.id, day: 1)
      @reader.archive!
      before = progress_snapshot

      refute_includes Bible270::Reader.daily_reminder_recipients(on: Bible270.today), @reader
      refute queued_notice.perform_deliveries
      queued_notice.deliver_now
      manual_notice = Bible270::NoticeMailer.daily_reminder(reader_id: @reader.id, day: 1)
      refute manual_notice.perform_deliveries
      manual_notice.deliver_now

      assert_empty ActionMailer::Base.deliveries
      assert @reader.reload.daily_reminders?
      assert_equal before, progress_snapshot
    end

    def test_broad_comment_recipients_exclude_alumni_without_changing_preferences
      @reader.update_comment_notification_level!('all')
      @other.update_comment_notification_level!('all')
      @reader.archive!
      Bible270.config.mention_notifications = true
      sign_in_as(@site_admin)

      post "#{mount}/day/1/comments", params: { comment: { body: 'A new group reflection' } }

      assert_response :redirect
      assert_equal [@other.id], Bible270::Reader.all_comment_notification_recipients.pluck(:id)
      assert_equal 1, ActionMailer::Base.deliveries.size
      assert_equal [@other.email], ActionMailer::Base.deliveries.last.bcc
      assert_equal 'all', @reader.reload.comment_notification_level
      assert @reader.wants_comment_notifications?
      assert @reader.alumni?
    end

    def test_broad_comment_mailer_rechecks_alumni_even_when_explicitly_given_their_id
      @reader.update_comment_notification_level!('all')
      @other.update_comment_notification_level!('all')
      comment = @site_admin.comments.create!(day: 1, body: 'A reflection for subscribers')
      @reader.archive!
      Bible270.config.mention_notifications = true

      mail = Bible270::NoticeMailer.comment_posted(comment_id: comment.id, reader_ids: [@reader.id, @other.id])
      assert_equal [@other.email], mail.bcc
      alumni_only = Bible270::NoticeMailer.comment_posted(comment_id: comment.id, reader_ids: [@reader.id])
      refute alumni_only.perform_deliveries
    end

    def test_alumni_keep_personal_reply_and_mention_notifications
      @reader.update_comment_notification_level!('personal')
      thought = @reader.comments.create!(day: 1, body: 'An alumni conversation')
      @reader.archive!
      before = progress_snapshot
      Bible270.config.mention_notifications = true
      sign_in_as(@other)

      post "#{mount}/day/1/comments", params: { comment: { body: 'A personal reply', parent_id: thought.id } }
      assert_response :redirect
      assert_equal 1, ActionMailer::Base.deliveries.size
      assert_equal [@reader.email], ActionMailer::Base.deliveries.last.to
      assert_match(%r{replied}, ActionMailer::Base.deliveries.last.subject)
      post "#{mount}/day/1/comments", params: { comment: { body: 'A personal mention for @Alumni' } }
      assert_response :redirect
      assert_equal 2, ActionMailer::Base.deliveries.size
      assert_equal [@reader.email], ActionMailer::Base.deliveries.last.to
      assert_match(%r{mentioned you}, ActionMailer::Base.deliveries.last.subject)
      assert_equal 'personal', @reader.reload.comment_notification_level
      assert_equal before, progress_snapshot
    end

    def test_alumni_personal_notification_opt_out_is_still_respected
      @reader.update_comment_notification_level!('none')
      thought = @reader.comments.create!(day: 1, body: 'An older reflection')
      @reader.archive!
      Bible270.config.mention_notifications = true
      sign_in_as(@other)

      post "#{mount}/day/1/comments", params: { comment: { body: 'Reply for @Alumni', parent_id: thought.id } }
      assert_response :redirect
      post "#{mount}/day/1/comments", params: { comment: { body: 'Another mention for @Alumni' } }
      assert_response :redirect

      assert_empty ActionMailer::Base.deliveries
      assert_equal 'none', @reader.reload.comment_notification_level
      assert @reader.alumni?
    end

  private

    def mount = Bible270.config.mount_at.chomp('/')

    def turbo_stream_headers = { 'Accept' => 'text/vnd.turbo-stream.html' }

    def create_reader(name, email)
      Bible270::Reader.create!(provider: 'email', uid: email, email: email,
                               display_name: name, first_name: name, last_name: 'Reader',
                               notify_on_mention: false, notify_on_all_comments: false)
    end

    def sign_in_as(reader, browser: self)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      browser.get "#{mount}/sign_in/email/#{raw}"
      browser.assert_response :redirect
    end

    def admin_browser
      @admin_browser ||= open_session.tap { |browser| sign_in_as(@site_admin, browser: browser) }
    end

    def restart_run!
      old_run_id = Bible270::PlanRun.current.id
      admin_browser.post "#{mount}/admin/restart", params: {
        start_date: Bible270.today.to_s, expected_run_id: old_run_id, confirm_restart: '1'
      }
      admin_browser.assert_redirected_to "#{mount}/admin"
      refute_equal old_run_id, Bible270::PlanRun.current.id
      @reader.reload.reload_progress
    end

    def reactivate_reader!
      admin_browser.patch "#{mount}/admin/readers/#{@reader.id}/participation", params: {
        status: 'active', expected_run_id: Bible270::PlanRun.current.id
      }
      admin_browser.assert_redirected_to "#{mount}/admin/readers/#{@reader.id}"
      @reader.reload.reload_progress
      refute @reader.alumni?
    end

    def community_reader_ids
      css_select('.b270-community-reader-details .name a').map { |link| link['href'].split('/').last.to_i }.sort
    end

    def progress_snapshot
      {
        checkoffs: Bible270::Checkoff.order(:id).map(&:attributes),
        participations: Bible270::Participation.order(:id).map(&:attributes),
        personal_dates: Bible270::Reader.order(:id).pluck(:id, :started_on)
      }
    end

    def assert_alumni_can_participate(headers:)
      thought = @other.comments.create!(day: 1, body: 'A conversation to join')
      restart_run!
      before = progress_snapshot
      sign_in_as(@reader)

      assert_difference('Bible270::Comment.count', 1) do
        post "#{mount}/day/1/comments", params: { comment: { body: 'Still part of the conversation' } }, headers: headers
      end
      assert_response(headers.empty? ? :redirect : :success)
      reflection = @reader.comments.find_by!(body: 'Still part of the conversation')
      assert_nil reflection.parent_id
      assert_difference('Bible270::Comment.count', 1) do
        post "#{mount}/day/1/comments",
             params: { comment: { body: 'An alumni reply', parent_id: thought.id } }, headers: headers
      end
      assert_response(headers.empty? ? :redirect : :success)
      assert_equal thought.id, @reader.comments.find_by!(body: 'An alumni reply').parent_id
      post "#{mount}/comments/#{thought.id}/like", params: { liked: '1' }, headers: headers
      assert_response(headers.empty? ? :redirect : :success)
      assert thought.reload.liked_by?(@reader)
      post "#{mount}/comments/#{thought.id}/like", params: { liked: '0' }, headers: headers
      assert_response(headers.empty? ? :redirect : :success)
      refute thought.reload.liked_by?(@reader)
      assert @reader.reload.alumni?
      assert_equal before, progress_snapshot
      assert_empty ActionMailer::Base.deliveries
    end

    def assert_alumni_checkoffs_blocked(headers:)
      @reader.mark_day_complete!(1)
      @reader.archive!
      sign_in_as(@reader)
      before = progress_snapshot
      [1, 2].each do |day|
        [nil, '0', '1'].each do |checked|
          params = { participation_id: @reader.participation.id }
          params[:checked] = checked unless checked.nil?
          post "#{mount}/day/#{day}/toggle/nt/0", params: params, headers: headers

          if headers.empty?
            assert_response :redirect
            assert_match(%r{read-only}i, flash[:alert] || flash[:notice])
          else
            assert_response :forbidden
          end
          assert_equal before, progress_snapshot
          assert @reader.reload.alumni?
        end
      end
    end

    def assert_stale_forms_rejected(headers:)
      @reader.checkoffs.create!(day: 1, track: 'nt', part: 0)
      sign_in_as(@reader)
      get "#{mount}/day/1"
      assert_response :success
      old_membership_id = @reader.participation.id
      stale_forms = %w[nt ot].map do |track|
        form = css_select("form[action='#{mount}/day/1/toggle/#{track}/0']").first
        assert form, "expected a checkoff form for #{track}"
        params = form.css('input[type="hidden"][name]').to_h { |input| [input['name'], input['value']] }
        assert_equal old_membership_id.to_s, params['participation_id']
        [form['action'], params]
      end
      assert_equal(%w[0 1], stale_forms.map { |_, params| params.fetch('checked') })
      restart_run!
      reactivate_reader!
      @reader.checkoffs.create!(day: 1, track: 'nt', part: 0)
      before = progress_snapshot

      stale_forms.each do |action, params|
        post action, params: params, headers: headers

        if headers.empty?
          assert_redirected_to "#{mount}/day/1"
          assert_match(%r{run changed|reload}i, flash[:alert] || flash[:notice])
        else
          assert_response :conflict
        end
        assert_equal before, progress_snapshot
      end
    end
  end
end
