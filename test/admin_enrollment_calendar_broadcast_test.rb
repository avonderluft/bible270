# frozen_string_literal: true

require_relative 'support/admin_controller_test_case'

if RAILS_LOADED
  class AdminEnrollmentCalendarBroadcastTest < Bible270AdminControllerTestCase
    # ---- writing to everyone ------------------------------------------------

    def test_the_panel_offers_a_recipient_selector
      sign_in_as_admin

      get "#{mount}/admin"

      assert_response :success
      assert_select 'h2', text: 'Write a message'
      assert_select 'label.b270-sr-only[for="b270-broadcast-audience"]', text: 'Recipients'
      assert_select 'form[action$="/admin/broadcast"] select#b270-broadcast-audience[name="audience"]' do
        assert_select 'option[value="everyone"][selected="selected"]', text: 'Write to everyone'
        assert_select 'option[value="admins"]', text: 'Write to all admins'
      end
      assert_match(%r{2 readers}, response.body, 'says how many readers can receive email')
      assert_match(%r{1 admin}, response.body, 'says how many admins can receive email')
    end

    def test_a_message_goes_to_every_reader_with_an_address
      ActionMailer::Base.deliveries.clear
      sign_in_as_admin

      post "#{mount}/admin/broadcast", params: { subject: 'A word', body: 'Grace and peace.' }

      assert_equal 2, ActionMailer::Base.deliveries.size
      assert_equal [@admin.email, @reader.email].sort,
                   ActionMailer::Base.deliveries.map { |mail| mail.to.first }.sort
    end

    def test_a_message_can_be_sent_only_to_configured_admin_emails
      other_admin = Bible270::Reader.create!(provider: 'email', uid: 'admin@example.org',
                                             email: 'admin@example.org', display_name: 'Other Admin')
      sign_in_as_admin
      Bible270.config.admin_emails = [@admin.email, other_admin.email]
      ActionMailer::Base.deliveries.clear

      post "#{mount}/admin/broadcast",
           params: { audience: 'admins', subject: 'Admins', body: 'For administrators.' }

      assert_equal [@admin.email, other_admin.email].sort,
                   ActionMailer::Base.deliveries.map { |mail| mail.to.first }.sort
      assert_match(%r{Sent to 2 admins}, flash[:notice].to_s)
    end

    def test_a_message_to_admins_honors_a_custom_admin_resolver
      resolver_admin = Bible270::Reader.create!(provider: 'email', uid: 'resolver@example.org',
                                                email: 'resolver@example.org', display_name: 'Resolver Admin')
      sign_in_as_admin
      admin_ids = [@admin.id, resolver_admin.id]
      Bible270.config.admin_resolver = ->(reader) { admin_ids.include?(reader.id) }
      ActionMailer::Base.deliveries.clear

      post "#{mount}/admin/broadcast",
           params: { audience: 'admins', subject: 'Admins', body: 'For administrators.' }

      assert_equal [@admin.email, resolver_admin.email].sort,
                   ActionMailer::Base.deliveries.map { |mail| mail.to.first }.sort
      assert_match(%r{Sent to 2 admins}, flash[:notice].to_s)
    end

    def test_an_unknown_broadcast_audience_is_refused
      sign_in_as_admin
      ActionMailer::Base.deliveries.clear

      post "#{mount}/admin/broadcast",
           params: { audience: 'outsiders', subject: 'No', body: 'Do not send.' }

      assert_empty ActionMailer::Base.deliveries
      assert_match(%r{Choose who should receive}, flash[:alert].to_s)
    end

    # One message each, not one message with everyone in bcc.
    def test_each_reader_gets_their_own_message
      ActionMailer::Base.deliveries.clear
      sign_in_as_admin

      post "#{mount}/admin/broadcast", params: { subject: 'A word', body: 'Grace and peace.' }

      ActionMailer::Base.deliveries.each do |mail|
        assert_equal 1, mail.to.size
        assert_nil mail.bcc
      end
    end

    def test_the_message_greets_the_reader_by_name
      ActionMailer::Base.deliveries.clear
      sign_in_as_admin

      post "#{mount}/admin/broadcast", params: { subject: 'A word', body: 'Grace and peace.' }

      to_reader = ActionMailer::Base.deliveries.find { |mail| mail.to == [@reader.email] }
      body = to_reader.multipart? ? to_reader.all_parts.map { |p| p.body.to_s }.join : to_reader.body.to_s

      assert_match(%r{\bR\b}, body, 'their first name')
      assert_match(%r{Grace and peace}, body)
      assert_equal 'A word', to_reader.subject
    end

    def test_a_reader_without_an_address_is_skipped
      Bible270::Reader.create!(provider: 'owner', uid: 'host-1', display_name: 'No Email')
      ActionMailer::Base.deliveries.clear
      sign_in_as_admin

      post "#{mount}/admin/broadcast", params: { subject: 'A word', body: 'Something' }

      assert_equal 2, ActionMailer::Base.deliveries.size, 'the two with addresses'
    end

    def test_a_broadcast_continues_after_a_failure_and_counts_only_successes
      failing_id = @reader.id
      attempted = []
      broadcaster = ->(reader_id:, **_message) do
        attempted << reader_id
        delivery = Object.new
        delivery.define_singleton_method(:deliver_now) do
          raise 'SMTP failure' if reader_id == failing_id

          true
        end
        delivery
      end
      sign_in_as_admin

      Bible270::NoticeMailer.stub(:broadcast, broadcaster) do
        post "#{mount}/admin/broadcast", params: { subject: 'A word', body: 'Something' }
      end

      assert_equal [@admin.id, @reader.id].sort, attempted.sort
      assert_match(%r{Sent to 1 reader}, flash[:notice].to_s)
      assert_match(%r{1 reader could not be sent}, flash[:notice].to_s)
      assert_equal 'A word', Bible270::Setting.read(Bible270::AdminController::LAST_BROADCAST_SUBJECT)
      refute_nil Bible270::Setting.read(Bible270::AdminController::LAST_BROADCAST_AT)
    end

    def test_a_total_broadcast_failure_is_an_alert_and_records_no_success
      broadcaster = ->(**_message) do
        delivery = Object.new
        delivery.define_singleton_method(:deliver_now) { raise 'SMTP failure' }
        delivery
      end
      sign_in_as_admin

      Bible270::NoticeMailer.stub(:broadcast, broadcaster) do
        post "#{mount}/admin/broadcast", params: { subject: 'A word', body: 'Something' }
      end

      assert_match(%r{could not be sent to any readers}, flash[:alert].to_s)
      refute_match(%r{Sent to|Queued for}, flash[:notice].to_s)
      assert_nil Bible270::Setting.read(Bible270::AdminController::LAST_BROADCAST_SUBJECT)
      assert_nil Bible270::Setting.read(Bible270::AdminController::LAST_BROADCAST_AT)
    end

    def test_a_deferred_broadcast_says_it_was_queued
      attempted = []
      broadcaster = ->(reader_id:, **_message) do
        delivery = Object.new
        delivery.define_singleton_method(:deliver_later) { attempted << reader_id }
        delivery
      end
      Bible270.config.registration_notice_deliver_later = true
      sign_in_as_admin

      Bible270::NoticeMailer.stub(:broadcast, broadcaster) do
        post "#{mount}/admin/broadcast", params: { subject: 'A word', body: 'Something' }
      end

      assert_equal [@admin.id, @reader.id].sort, attempted.sort
      assert_match(%r{Queued for 2 readers}, flash[:notice].to_s)
    end

    def test_a_no_recipient_broadcast_works_for_an_admin_without_email
      sign_in_as_admin
      @admin.update_column(:email, nil)
      @reader.update_column(:email, nil)
      admin_id = @admin.id
      Bible270.config.admin_emails = []
      Bible270.config.admin_resolver = ->(reader) { reader.id == admin_id }

      post "#{mount}/admin/broadcast", params: { subject: 'A word', body: 'Something' }

      assert_match(%r{Nobody has an email address}, flash[:alert].to_s)
      assert_nil Bible270::Setting.read(Bible270::AdminController::LAST_BROADCAST_SUBJECT)
      assert_nil Bible270::Setting.read(Bible270::AdminController::LAST_BROADCAST_AT)
    end

    def test_an_empty_message_is_refused
      ActionMailer::Base.deliveries.clear
      sign_in_as_admin

      post "#{mount}/admin/broadcast", params: { subject: '', body: 'Something' }
      post "#{mount}/admin/broadcast", params: { subject: 'A word', body: '   ' }

      assert_empty ActionMailer::Base.deliveries
      assert_match(%r{subject}, flash[:alert].to_s)
    end

    def test_it_remembers_when_it_last_wrote
      sign_in_as_admin
      post "#{mount}/admin/broadcast", params: { subject: 'A word', body: 'Something' }

      get "#{mount}/admin"

      assert_match(%r{Last sent}, response.body)
      assert_match(%r{A word}, response.body)
    end

    def test_an_ordinary_reader_cannot_write_to_everyone
      ActionMailer::Base.deliveries.clear
      sign_in_as(@reader)

      post "#{mount}/admin/broadcast", params: { subject: 'Spam', body: 'Buy things' }

      assert_response :not_found
      assert_empty ActionMailer::Base.deliveries
    end

    def test_a_visitor_cannot_broadcast
      ActionMailer::Base.deliveries.clear

      post "#{mount}/admin/broadcast", params: { subject: 'Spam', body: 'Buy things' }

      assert_response :not_found
      assert_empty ActionMailer::Base.deliveries
    end

    # ---- current run -------------------------------------------------------

    def test_the_panel_shows_the_effective_run_date_and_affected_readers
      Bible270.config.start_date = Date.new(2026, 9, 6)
      sign_in_as_admin

      get "#{mount}/admin"

      assert_select 'h2', text: 'Current run start date'
      assert_select 'input[name="start_date"][value="2026-09-06"]'
      assert_match(%r{This affects 2 readers following the shared calendar}, response.body)
      assert_select '.b270-badge', text: 'Admin override', count: 0
    end

    def test_personal_calendar_counts_are_disabled_with_the_feature
      @reader.set_start_date!('2026-07-01')
      Bible270.config.allow_reader_start_date = false
      sign_in_as_admin

      get "#{mount}/admin"

      assert_match(%r{This affects 2 readers following the shared calendar}, response.body)
      refute_match(%r{with a personal calendar}, response.body)
    end

    def test_a_corrupt_broadcast_timestamp_is_treated_as_absent
      Bible270::Setting.write(Bible270::AdminController::LAST_BROADCAST_AT, 'not a timestamp')
      Bible270::Setting.write(Bible270::AdminController::LAST_BROADCAST_SUBJECT, 'Old subject')
      sign_in_as_admin

      get "#{mount}/admin"

      assert_response :success
      refute_match(%r{Last sent}, response.body)
      refute_match(%r{Old subject}, response.body)
    end

    def test_an_admin_can_override_the_current_run_start_date
      Bible270.config.start_date = Date.new(2026, 9, 6)
      sign_in_as_admin

      patch "#{mount}/admin/run-start", params: { start_date: '2026-08-02' }

      assert_response :redirect
      assert_equal Date.new(2026, 8, 2), Bible270::Setting.run_start_date
      assert Bible270::Setting.run_start_date_overridden?
      assert_equal Date.new(2026, 8, 2), @reader.reload.effective_start_date
    end

    def test_a_run_date_change_does_not_move_a_personal_calendar
      @reader.set_start_date!('2026-07-01')
      sign_in_as_admin

      patch "#{mount}/admin/run-start", params: { start_date: '2026-08-02' }

      assert_equal Date.new(2026, 7, 1), @reader.reload.effective_start_date
    end

    def test_an_admin_can_restore_the_configured_start_date
      Bible270.config.start_date = Date.new(2026, 9, 6)
      Bible270::Setting.set_run_start_date!('2026-08-02')
      sign_in_as_admin

      delete "#{mount}/admin/run-start"

      assert_response :redirect
      assert_equal Date.new(2026, 9, 6), Bible270::Setting.run_start_date
      refute Bible270::Setting.run_start_date_overridden?
    end

    def test_resetting_without_a_configured_date_restores_the_undated_schedule
      Bible270.config.start_date = nil
      Bible270::Setting.set_run_start_date!('2026-08-02')
      sign_in_as_admin

      delete "#{mount}/admin/run-start"

      assert_response :redirect
      assert_nil Bible270::Setting.run_start_date
      refute Bible270::Setting.run_start_date_overridden?
      assert_match(%r{undated schedule}, flash[:notice].to_s)
    end

    def test_an_invalid_run_start_date_is_refused
      sign_in_as_admin

      patch "#{mount}/admin/run-start", params: { start_date: 'not a date' }

      assert_response :redirect
      refute Bible270::Setting.run_start_date_overridden?
      assert_match(%r{valid start date}, flash[:alert].to_s)
    end

    def test_an_ordinary_reader_cannot_change_the_current_run_start_date
      sign_in_as(@reader)

      patch "#{mount}/admin/run-start", params: { start_date: '2026-08-02' }

      assert_response :not_found
      refute Bible270::Setting.run_start_date_overridden?
    end

    # ---- closing a run -----------------------------------------------------

    def test_an_admin_can_close_and_reopen_the_run
      sign_in_as_admin

      patch "#{mount}/admin/enrollment", params: { state: 'closed' }
      assert Bible270::Setting.enrollment_closed?

      patch "#{mount}/admin/enrollment", params: { state: 'open' }
      refute Bible270::Setting.enrollment_closed?
    end

    def test_missing_and_unknown_enrollment_states_preserve_the_setting_and_alert
      Bible270::Setting.close_enrollment!
      sign_in_as_admin

      [{}, { state: nil }, { state: 'unknown' }].each do |params|
        patch "#{mount}/admin/enrollment", params: params

        assert_response :redirect
        assert Bible270::Setting.enrollment_closed?, "opened enrollment for #{params.inspect}"
        assert_match(%r{Nothing was changed}, flash[:alert].to_s)
      end

      Bible270::Setting.open_enrollment!
      patch "#{mount}/admin/enrollment", params: { state: 'CLOSED' }
      refute Bible270::Setting.enrollment_closed?
      assert_match(%r{Nothing was changed}, flash[:alert].to_s)
    end
  end
end
