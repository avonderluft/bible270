# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class AdminControllerTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_admins = Bible270.config.admin_emails
      @previous_start_date = Bible270.config.start_date
      @previous_personal_dates = Bible270.config.allow_reader_start_date
      @admin = Bible270::Reader.create!(provider: 'email', uid: 'boss@example.org',
                                        email: 'boss@example.org', display_name: 'The Boss')
      @reader = Bible270::Reader.create!(provider: 'email', uid: 'r@example.org',
                                         email: 'r@example.org', display_name: 'R Reader',
                                         first_name: 'R', last_name: 'Reader')
    end

    def teardown
      Bible270.config.admin_emails = @previous_admins
      Bible270.config.start_date = @previous_start_date
      Bible270.config.allow_reader_start_date = @previous_personal_dates
      Bible270::Setting.open_enrollment!
      Bible270::Setting.clear_run_start_date!
    end

    def mount = Bible270.config.mount_at.chomp('/')

    def sign_in_as(reader)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"
    end

    def sign_in_as_admin
      Bible270.config.admin_emails = [@admin.email]
      sign_in_as(@admin)
    end

    # Unauthorised requests 404 rather than 403, so the panel's existence isn't
    # advertised to someone poking at URLs.
    def test_the_panel_is_hidden_from_a_visitor
      get "#{mount}/admin"
      refute_equal 200, response.status
    end

    def test_the_panel_is_hidden_from_an_ordinary_reader
      sign_in_as(@reader)
      get "#{mount}/admin"

      refute_equal 200, response.status
    end

    def test_an_admin_sees_the_reader_list
      sign_in_as_admin
      get "#{mount}/admin"

      assert_response :success
      assert_match(%r{R Reader}, response.body)
    end

    # The community page lists people by first name, so the admin list should too:
    # surname order read oddly beside names displayed first-name-first.
    def test_the_reader_list_is_ordered_by_first_name
      Bible270::Reader.create!(provider: 'email', uid: 'z@example.org', email: 'z@example.org',
                               display_name: 'Aaron Zebedee', first_name: 'Aaron', last_name: 'Zebedee')
      Bible270::Reader.create!(provider: 'email', uid: 'y@example.org', email: 'y@example.org',
                               display_name: 'Zeke Aaronson', first_name: 'Zeke', last_name: 'Aaronson')
      sign_in_as_admin

      get "#{mount}/admin"

      assert_response :success
      assert_operator response.body.index('Aaron Zebedee'), :<, response.body.index('Zeke Aaronson'),
                      'Aaron should precede Zeke, despite Zebedee following Aaronson'
    end

    def test_an_admin_sees_a_reader
      sign_in_as_admin
      get "#{mount}/admin/readers/#{@reader.id}"

      assert_response :success
      assert_match(%r{R Reader}, response.body)
    end

    def test_an_admin_can_rename_a_reader
      sign_in_as_admin
      patch "#{mount}/admin/readers/#{@reader.id}/profile",
            params: { first_name: 'Renamed', last_name: 'Person' }

      assert_equal 'Renamed Person', @reader.reload.display_name
    end

    def test_an_admin_can_set_progress_exactly
      sign_in_as_admin
      patch "#{mount}/admin/readers/#{@reader.id}/through", params: { day: 3 }

      assert_equal 3, @reader.reload.days_completed
    end

    def test_an_admin_can_toggle_a_single_day
      sign_in_as_admin
      post "#{mount}/admin/readers/#{@reader.id}/days/5"

      assert @reader.reload.day_complete?(5)

      post "#{mount}/admin/readers/#{@reader.id}/days/5"
      assert_equal 0, @reader.reload.checkoffs.where(day: 5).count
    end

    def test_an_admin_can_move_a_reader_to_a_day
      sign_in_as_admin
      patch "#{mount}/admin/readers/#{@reader.id}/start", params: { day: 42 }

      refute_nil @reader.reload.started_on
      # Bible270.today, not Date.current: the latter is UTC unless the host sets a
      # zone, so on a machine behind UTC this asserted a day too far ahead.
      assert_equal 42, Bible270::Plan.day_for(Bible270.today, @reader.started_on)
    end

    # Personal calendars may be disabled while an administrator prepares a date
    # that will take effect if they are enabled later.
    def test_an_admin_can_set_a_date_when_personal_calendars_are_disabled
      previous = Bible270.config.allow_reader_start_date
      Bible270.config.allow_reader_start_date = false
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/start", params: { start_date: '2026-09-06' }

      assert_equal Date.new(2026, 9, 6), @reader.reload.started_on
    ensure
      Bible270.config.allow_reader_start_date = previous
    end

    def test_an_admin_can_remove_a_reader
      sign_in_as_admin
      id = @reader.id
      delete "#{mount}/admin/readers/#{id}"

      refute Bible270::Reader.exists?(id)
    end

    def test_removing_a_reader_takes_their_reflections_with_them
      @reader.comments.create!(day: 1, body: 'Something')
      sign_in_as_admin

      delete "#{mount}/admin/readers/#{@reader.id}"

      assert_equal 0, Bible270::Comment.count
    end

    # ---- moderation --------------------------------------------------------

    def test_an_admin_can_hide_and_restore_a_reflection
      comment = @reader.comments.create!(day: 1, body: 'Questionable')
      sign_in_as_admin

      patch "#{mount}/admin/comments/#{comment.id}/hide"
      assert comment.reload.hidden?

      patch "#{mount}/admin/comments/#{comment.id}/unhide"
      refute comment.reload.hidden?
    end

    def test_hiding_keeps_the_words
      comment = @reader.comments.create!(day: 1, body: 'Kept')
      sign_in_as_admin
      patch "#{mount}/admin/comments/#{comment.id}/hide"

      assert_equal 'Kept', comment.reload.body
      assert_equal 1, Bible270::Comment.count
    end

    def test_an_admin_can_delete_a_reflection_outright
      comment = @reader.comments.create!(day: 1, body: 'Gone')
      sign_in_as_admin

      delete "#{mount}/admin/comments/#{comment.id}"

      assert_equal 0, Bible270::Comment.count
    end

    def test_the_moderation_list_renders
      @reader.comments.create!(day: 1, body: 'On the list')
      sign_in_as_admin

      get "#{mount}/admin/comments"

      assert_response :success
      assert_match(%r{On the list}, response.body)
    end

    def test_the_moderation_list_marks_replies
      thought = @reader.comments.create!(day: 1, body: 'A reflection')
      @reader.comments.create!(day: 1, body: 'An answer', parent: thought)
      sign_in_as_admin

      get "#{mount}/admin/comments"

      assert_response :success
      assert_match(%r{reply to}, response.body)
    end

    def test_hiding_a_reply_leaves_the_thread
      thought = @reader.comments.create!(day: 1, body: 'A reflection')
      reply = @reader.comments.create!(day: 1, body: 'An answer', parent: thought)
      sign_in_as_admin

      patch "#{mount}/admin/comments/#{reply.id}/hide"

      assert reply.reload.hidden?
      refute thought.reload.hidden?, 'hiding a reply must not hide what it answered'
    end

    # ---- which translation a reader gets ------------------------------------

    def test_the_page_shows_a_readers_translation
      @reader.update_bible_version('KJV')
      sign_in_as_admin

      get "#{mount}/admin/readers/#{@reader.id}"

      assert_response :success
      assert_match(%r{Which translation they read}, response.body)
      assert_match(%r{<option selected="selected" value="KJV">}, response.body)
      assert_match(%r{name="bible_version".*class="b270-source-choices"}m, response.body,
                   'reader choice belongs immediately below the translation selector')
      assert_equal 2, response.body.scan(%r{name="passage_source"}).size
      assert_match(%r{value="bible_gateway" checked="checked"}, response.body)
    end

    def test_it_says_when_a_reader_has_no_preference
      sign_in_as_admin

      get "#{mount}/admin/readers/#{@reader.id}"

      assert_match(%r{no preference}, response.body)
      assert_match(%r{Site default}, response.body)
    end

    def test_an_admin_can_set_a_readers_translation
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/version", params: { bible_version: 'LSB' }

      assert_equal 'LSB', @reader.reload.bible_version
      assert_equal 'LSB', @reader.effective_bible_version
    end

    def test_an_admin_can_choose_blue_letter_bible_for_a_reader
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/version",
            params: { bible_version: 'LSB', passage_source: 'blue_letter_bible' }

      assert_equal 'blue_letter_bible', @reader.reload.passage_source
    end

    def test_an_admin_cannot_set_an_unknown_passage_source
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/version",
            params: { bible_version: 'LSB', passage_source: 'unknown' }

      assert_equal 'bible_gateway', @reader.reload.passage_source
      assert_match(%r{not a reading-link source}, flash[:alert].to_s)
    end

    def test_an_admin_can_return_a_reader_to_bible_gateway
      @reader.update!(passage_source: 'blue_letter_bible')
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/version", params: { bible_version: 'LSB' }

      assert_equal 'bible_gateway', @reader.reload.passage_source
    end

    # Blank is not the same as picking today's default: it means follow whatever
    # the site uses, including after the site changes it.
    def test_clearing_it_returns_them_to_the_site_default
      @reader.update_bible_version('KJV')
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/version", params: { bible_version: '' }

      assert_nil @reader.reload.bible_version
      assert_equal Bible270.config.bible_version, @reader.effective_bible_version
    end

    def test_an_unknown_translation_is_refused
      @reader.update_bible_version('KJV')
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/version", params: { bible_version: 'NIV' }

      assert_equal 'KJV', @reader.reload.bible_version, 'unchanged'
      assert_match(%r{not a translation}, flash[:alert].to_s)
    end

    def test_an_ordinary_reader_cannot_set_someone_elses_translation
      sign_in_as(@reader)

      patch "#{mount}/admin/readers/#{@admin.id}/version", params: { bible_version: 'KJV' }

      refute_equal 200, response.status
      assert_nil @admin.reload.bible_version
    end

    def test_a_visitor_cannot_either
      patch "#{mount}/admin/readers/#{@reader.id}/version", params: { bible_version: 'KJV' }

      assert_nil @reader.reload.bible_version
    end

    # The point of the setting: reading links open in their translation.
    def test_the_choice_reaches_the_readers_day_page
      sign_in_as_admin
      patch "#{mount}/admin/readers/#{@reader.id}/version", params: { bible_version: 'KJV' }
      reset!

      _record, raw = Bible270::SignInToken.issue!(@reader.email)
      get "#{mount}/sign_in/email/#{raw}"
      get "#{mount}/day/1"

      assert_match(%r{version=KJV}, response.body)
    end

    def test_the_blue_letter_bible_choice_reaches_the_readers_day_page
      sign_in_as_admin
      patch "#{mount}/admin/readers/#{@reader.id}/version",
            params: { bible_version: 'KJV', passage_source: 'blue_letter_bible' }
      reset!

      _record, raw = Bible270::SignInToken.issue!(@reader.email)
      get "#{mount}/sign_in/email/#{raw}"
      get "#{mount}/day/1"

      assert_match(%r{blueletterbible\.org/kjv/gen/1/1/s_1001}, response.body)
    end

    # ---- moderating from the page itself -----------------------------------

    def test_an_admin_sees_delete_on_someone_elses_reflection
      @reader.comments.create!(day: 1, body: 'Not the admin\'s')
      sign_in_as_admin

      get "#{mount}/day/1"

      assert_response :success
      assert_match(%r{class="b270-cdel"}, response.body)
    end

    def test_an_admin_can_delete_someone_elses_reflection
      comment = @reader.comments.create!(day: 1, body: 'Questionable')
      sign_in_as_admin

      delete "#{mount}/comments/#{comment.id}"

      refute Bible270::Comment.exists?(comment.id)
    end

    # Removing someone's words is the moderator's job; rewriting them is not.
    def test_an_admin_cannot_edit_someone_elses_reflection
      comment = @reader.comments.create!(day: 1, body: 'Their words')
      sign_in_as_admin

      patch "#{mount}/comments/#{comment.id}", params: { comment: { body: 'My words' } }

      assert_response :not_found
      assert_equal 'Their words', comment.reload.body
    end

    def test_an_admin_sees_no_edit_link_on_someone_elses
      @reader.comments.create!(day: 1, body: 'Their words')
      sign_in_as_admin

      get "#{mount}/day/1"

      refute_match(%r{edit=}, response.body)
    end

    # Deleting another person's reflection asks first; deleting your own does not.
    def test_removing_someone_elses_asks_for_confirmation
      @reader.comments.create!(day: 1, body: 'Theirs')
      sign_in_as_admin

      get "#{mount}/day/1"

      assert_match(%r{turbo-confirm}, response.body)
    end

    # ---- writing to everyone ------------------------------------------------

    def test_the_panel_offers_to_write_to_everyone
      sign_in_as_admin

      get "#{mount}/admin"

      assert_response :success
      assert_match(%r{Write to everyone}, response.body)
      assert_match(%r{2 readers}, response.body, 'says how many it will reach')
    end

    def test_a_message_goes_to_every_reader_with_an_address
      ActionMailer::Base.deliveries.clear
      sign_in_as_admin

      post "#{mount}/admin/broadcast", params: { subject: 'A word', body: 'Grace and peace.' }

      assert_equal 2, ActionMailer::Base.deliveries.size
      assert_equal [@admin.email, @reader.email].sort,
                   ActionMailer::Base.deliveries.map { |mail| mail.to.first }.sort
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

      assert_empty ActionMailer::Base.deliveries
    end

    def test_a_visitor_cannot_either
      ActionMailer::Base.deliveries.clear

      post "#{mount}/admin/broadcast", params: { subject: 'Spam', body: 'Buy things' }

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

      refute_equal 200, response.status
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
  end
end
