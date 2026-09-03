# frozen_string_literal: true

require 'test_helper'
require 'tempfile'

if RAILS_LOADED
  class AdminControllerTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_admins = Bible270.config.admin_emails
      @previous_admin_resolver = Bible270.config.admin_resolver
      @previous_deliver_later = Bible270.config.registration_notice_deliver_later
      @previous_start_date = Bible270.config.start_date
      @previous_personal_dates = Bible270.config.allow_reader_start_date
      @previous_mention_notifications = Bible270.config.mention_notifications
      Bible270.config.admin_resolver = nil
      Bible270.config.registration_notice_deliver_later = false
      @admin = Bible270::Reader.create!(provider: 'email', uid: 'boss@example.org',
                                        email: 'boss@example.org', display_name: 'The Boss')
      @reader = Bible270::Reader.create!(provider: 'email', uid: 'r@example.org',
                                         email: 'r@example.org', display_name: 'R Reader',
                                         first_name: 'R', last_name: 'Reader')
    end

    def teardown
      Bible270.config.admin_emails = @previous_admins
      Bible270.config.admin_resolver = @previous_admin_resolver
      Bible270.config.registration_notice_deliver_later = @previous_deliver_later
      Bible270.config.start_date = @previous_start_date
      Bible270.config.allow_reader_start_date = @previous_personal_dates
      Bible270.config.mention_notifications = @previous_mention_notifications
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

    def with_uploaded_avatar(content_type: 'image/png', contents: 'avatar')
      file = Tempfile.new(['avatar', '.png'])
      file.binmode
      file.write(contents)
      file.rewind
      upload = Rack::Test::UploadedFile.new(
        file.path, content_type, true, original_filename: 'avatar.png'
      )
      yield upload
    ensure
      file&.close!
    end

    # Unauthorised requests 404 rather than 403, so the panel's existence isn't
    # advertised to someone poking at URLs.
    def test_the_panel_is_hidden_from_a_visitor
      get "#{mount}/admin"
      assert_response :not_found
    end

    def test_the_panel_is_hidden_from_an_ordinary_reader
      sign_in_as(@reader)
      get "#{mount}/admin"

      assert_response :not_found
    end

    def test_an_admin_sees_the_reader_list
      sign_in_as_admin
      get "#{mount}/admin"

      assert_response :success
      assert_match(%r{R Reader}, response.body)
      assert_select "a[aria-label='R Reader'][href='#{mount}/admin/readers/#{@reader.id}'] .b270-avatar", count: 1
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

    def test_a_stale_reader_id_redirects_with_an_alert_and_halts_the_action
      @reader.mark_day_complete!(1)
      original_checkoffs = @reader.checkoffs.count
      sign_in_as_admin

      get "#{mount}/admin/readers/999999"
      assert_redirected_to "#{mount}/admin"
      assert_match(%r{Reader not found}, flash[:alert].to_s)

      patch "#{mount}/admin/readers/999999/through", params: { day: 0 }
      assert_redirected_to "#{mount}/admin"
      assert_match(%r{Reader not found}, flash[:alert].to_s)
      assert_equal original_checkoffs, @reader.reload.checkoffs.count
    end

    def test_an_admin_sees_a_readers_reflection_email_setting
      sign_in_as_admin

      get "#{mount}/admin/readers/#{@reader.id}"

      assert_select 'h2', text: 'Email notifications'
      assert_select 'input[type="radio"][name="comment_notifications"]', count: 3
      assert_select 'input[name="comment_notifications"][value="personal"][checked="checked"]'
    end

    def test_an_admin_can_change_a_readers_reflection_email_setting
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/notifications",
            params: { comment_notifications: 'all' }

      assert_response :redirect
      assert_equal 'all', @reader.reload.comment_notification_level
    end

    def test_admin_reflection_email_controls_explain_a_pending_migration
      sign_in_as_admin

      Bible270::Reader.stub(:comment_notification_columns?, false) do
        get "#{mount}/admin/readers/#{@reader.id}"
        assert_select 'input[name="comment_notifications"]', count: 0
        assert_select '.b270-flash.alert', text: %r{pending Bible270 database migration}i

        patch "#{mount}/admin/readers/#{@reader.id}/notifications",
              params: { comment_notifications: 'all' }
        assert_equal 'personal', @reader.reload.comment_notification_level
        assert_match(%r{pending Bible270 database migration}i, flash[:alert])
      end
    end

    def test_admin_reflection_email_controls_respect_the_global_switch
      @reader.update_comment_notification_level!('all')
      Bible270.config.mention_notifications = false
      sign_in_as_admin

      get "#{mount}/admin/readers/#{@reader.id}"
      assert_select 'input[name="comment_notifications"]', count: 0
      assert_select '.b270-hint', text: %r{Reflection emails are disabled}i

      patch "#{mount}/admin/readers/#{@reader.id}/notifications",
            params: { comment_notifications: 'none' }
      assert_equal 'all', @reader.reload.comment_notification_level
    end

    def test_an_invalid_reflection_email_setting_is_refused_without_changing_it
      @reader.update_comment_notification_level!('all')
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/notifications",
            params: { comment_notifications: 'sometimes' }

      assert_response :redirect
      assert_equal 'all', @reader.reload.comment_notification_level
      assert_match(%r{from the list}, flash[:alert].to_s)
    end

    def test_an_admin_sees_a_readers_completion_animation_setting
      sign_in_as_admin

      get "#{mount}/admin/readers/#{@reader.id}"

      assert_select 'h2', text: 'Completion animation'
      assert_select 'input[type="checkbox"][name="completion_dove_disabled"]:not([checked])', count: 1
    end

    def test_an_admin_can_turn_a_readers_completion_animation_off_and_back_on
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/completion-animation",
            params: { completion_dove_disabled: '1' }
      assert_response :redirect
      assert @reader.reload.completion_dove_disabled?

      patch "#{mount}/admin/readers/#{@reader.id}/completion-animation"
      assert_response :redirect
      refute @reader.reload.completion_dove_disabled?
    end

    def test_admin_completion_animation_control_explains_a_pending_migration
      sign_in_as_admin

      Bible270::Reader.stub(:completion_dove_column?, false) do
        get "#{mount}/admin/readers/#{@reader.id}"
        assert_select 'input[name="completion_dove_disabled"]', count: 0
        assert_select '.b270-flash.alert', text: %r{pending Bible270 database migration}i

        patch "#{mount}/admin/readers/#{@reader.id}/completion-animation",
              params: { completion_dove_disabled: '1' }
        refute @reader.reload.completion_dove_disabled?
        assert_match(%r{pending Bible270 database migration}i, flash[:alert])
      end
    end

    def test_an_admin_can_rename_a_reader
      sign_in_as_admin
      patch "#{mount}/admin/readers/#{@reader.id}/profile",
            params: { first_name: 'Renamed', last_name: 'Person' }

      assert_equal 'Renamed Person', @reader.reload.display_name
    end

    def test_a_half_name_is_rejected_without_changing_the_reader
      original_names = @reader.attributes.slice('first_name', 'last_name', 'display_name')
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/profile",
            params: { first_name: 'Only', last_name: '' }

      assert_response :redirect
      assert_equal original_names, @reader.reload.attributes.slice('first_name', 'last_name', 'display_name')
      assert_match(%r{first and last name}, flash[:alert].to_s)
    end

    def test_an_invalid_avatar_does_not_partially_update_the_name
      skip 'Active Storage unavailable' unless Bible270::Reader.avatar_uploads?

      original_names = @reader.attributes.slice('first_name', 'last_name', 'display_name')
      sign_in_as_admin

      with_uploaded_avatar(content_type: 'image/svg+xml') do |avatar|
        patch "#{mount}/admin/readers/#{@reader.id}/profile",
              params: { first_name: 'Changed', last_name: 'Name', avatar: avatar }
      end

      assert_response :redirect
      assert_equal original_names, @reader.reload.attributes.slice('first_name', 'last_name', 'display_name')
      refute @reader.avatar_uploaded?
      assert_match(%r{PNG, JPEG, GIF or WebP}, flash[:alert].to_s)
    end

    def test_an_admin_can_upload_and_remove_a_readers_avatar
      skip 'Active Storage unavailable' unless Bible270::Reader.avatar_uploads?

      sign_in_as_admin
      with_uploaded_avatar do |avatar|
        patch "#{mount}/admin/readers/#{@reader.id}/profile", params: { avatar: avatar }
      end

      assert_response :redirect
      assert @reader.reload.avatar_uploaded?

      delete "#{mount}/admin/readers/#{@reader.id}/avatar"

      assert_response :redirect
      refute @reader.reload.avatar_uploaded?
    end

    def test_an_admin_can_set_progress_exactly
      sign_in_as_admin
      patch "#{mount}/admin/readers/#{@reader.id}/through", params: { day: 3 }

      assert_equal 3, @reader.reload.days_completed
    end

    def test_complete_through_rejects_missing_blank_malformed_and_out_of_range_days_without_changing_progress
      @reader.mark_through!(3)
      sign_in_as_admin

      [{}, { day: nil }, { day: '' }, { day: '42oops' }, { day: -1 }, { day: 271 }].each do |params|
        patch "#{mount}/admin/readers/#{@reader.id}/through", params: params

        assert_response :redirect
        assert_equal 3, @reader.reload.days_completed, "changed progress for #{params.inspect}"
        assert_match(%r{between 0 and 270}, flash[:alert].to_s)
      end
    end

    def test_complete_through_accepts_an_explicit_zero_to_clear_progress
      @reader.mark_through!(3)
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/through", params: { day: '0' }

      assert_response :redirect
      assert_equal 0, @reader.reload.days_completed
      assert_match(%r{cleared}, flash[:notice].to_s)
    end

    def test_an_admin_can_toggle_a_single_day
      sign_in_as_admin
      post "#{mount}/admin/readers/#{@reader.id}/days/5"

      assert @reader.reload.day_complete?(5)

      post "#{mount}/admin/readers/#{@reader.id}/days/5"
      assert_equal 0, @reader.reload.checkoffs.where(day: 5).count
    end

    def test_toggle_day_rejects_malformed_and_out_of_range_days_without_changing_progress
      @reader.mark_day_complete!(5)
      original_checkoffs = @reader.checkoffs.order(:day, :track, :part).pluck(:day, :track, :part)
      sign_in_as_admin

      %w[0 42oops 271].each do |day|
        post "#{mount}/admin/readers/#{@reader.id}/days/#{day}"

        assert_response :redirect
        assert_equal original_checkoffs, @reader.reload.checkoffs.order(:day, :track, :part).pluck(:day, :track, :part)
        assert_match(%r{outside the plan}, flash[:alert].to_s)
      end
    end

    def test_an_admin_can_move_a_reader_to_a_day
      sign_in_as_admin
      patch "#{mount}/admin/readers/#{@reader.id}/start", params: { day: 42 }

      refute_nil @reader.reload.started_on
      # Bible270.today, not Date.current: the latter is UTC unless the host sets a
      # zone, so on a machine behind UTC this asserted a day too far ahead.
      assert_equal 42, Bible270::Plan.day_for(Bible270.today, @reader.started_on)
    end

    def test_moving_a_reader_rejects_malformed_and_out_of_range_days_without_changing_the_date
      @reader.set_start_date!('2026-07-01')
      original_date = @reader.started_on
      sign_in_as_admin

      %w[0 42oops 271].each do |day|
        patch "#{mount}/admin/readers/#{@reader.id}/start", params: { day: day }

        assert_response :redirect
        assert_equal original_date, @reader.reload.started_on, "changed start date for #{day.inspect}"
        assert_match(%r{between 1 and 270}, flash[:alert].to_s)
      end
    end

    def test_an_invalid_reader_start_date_preserves_the_existing_date
      @reader.set_start_date!('2026-07-01')
      original_date = @reader.started_on
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/start", params: { start_date: 'not a date' }

      assert_response :redirect
      assert_equal original_date, @reader.reload.started_on
      assert_match(%r{Couldn't read}, flash[:alert].to_s)
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

    def test_removing_a_reader_cascades_checkoffs_threads_replies_likes_and_avatar_attachment
      @reader.mark_day_complete!(1)
      readers_root = @reader.comments.create!(day: 1, body: 'Reader root')
      reply_to_reader = @admin.comments.create!(day: 1, body: 'Admin reply', parent: readers_root)
      admins_root = @admin.comments.create!(day: 2, body: 'Admin root')
      readers_reply = @reader.comments.create!(day: 2, body: 'Reader reply', parent: admins_root)
      readers_root.toggle_like!(@admin)
      admins_root.toggle_like!(@reader)
      attachment_id = nil
      if Bible270::Reader.avatar_uploads?
        @reader.avatar.attach(io: StringIO.new('avatar'), filename: 'avatar.png', content_type: 'image/png')
        attachment_id = @reader.avatar_attachment.id
      end
      sign_in_as_admin

      perform_enqueued_jobs do
        delete "#{mount}/admin/readers/#{@reader.id}"
      end

      refute Bible270::Reader.exists?(@reader.id)
      assert_equal 0, Bible270::Checkoff.where(reader_id: @reader.id).count
      refute Bible270::Comment.exists?(readers_root.id)
      refute Bible270::Comment.exists?(reply_to_reader.id), 'replies to the deleted root should also go'
      refute Bible270::Comment.exists?(readers_reply.id)
      assert Bible270::Comment.exists?(admins_root.id), 'another reader’s root should remain'
      assert_equal 0, Bible270::Like.where(reader_id: @reader.id).count
      assert_equal 0, Bible270::Like.where(comment_id: readers_root.id).count
      refute ActiveStorage::Attachment.exists?(attachment_id) if attachment_id
    end

    def test_an_ordinary_reader_cannot_delete_another_reader
      sign_in_as(@reader)
      reader_count = Bible270::Reader.count

      delete "#{mount}/admin/readers/#{@admin.id}"

      assert_response :not_found
      assert_equal reader_count, Bible270::Reader.count
      assert Bible270::Reader.exists?(@admin.id)
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

    def test_an_ordinary_reader_cannot_delete_an_admins_reflection
      comment = @admin.comments.create!(day: 1, body: 'Admin reflection')
      sign_in_as(@reader)

      delete "#{mount}/admin/comments/#{comment.id}"

      assert_response :not_found
      assert Bible270::Comment.exists?(comment.id)
      assert_equal 'Admin reflection', comment.reload.body
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

    def test_the_moderation_list_filters_visible_and_hidden_reflections
      visible = @reader.comments.create!(day: 1, body: 'Visible words')
      hidden = @reader.comments.create!(day: 2, body: 'Hidden words')
      hidden.hide!
      sign_in_as_admin

      get "#{mount}/admin/comments", params: { filter: 'visible' }
      assert_match(%r{#{Regexp.escape(visible.body)}}, response.body)
      refute_match(%r{#{Regexp.escape(hidden.body)}}, response.body)

      get "#{mount}/admin/comments", params: { filter: 'hidden' }
      assert_match(%r{#{Regexp.escape(hidden.body)}}, response.body)
      refute_match(%r{#{Regexp.escape(visible.body)}}, response.body)
    end

    def test_moderation_actions_retain_the_current_filter
      comment = @reader.comments.create!(day: 1, body: 'Hidden words')
      comment.hide!
      sign_in_as_admin
      return_to = "#{mount}/admin/comments?filter=hidden"

      patch "#{mount}/admin/comments/#{comment.id}/unhide", params: { return_to: return_to }

      assert_redirected_to return_to
      refute comment.reload.hidden?
    end

    def test_moderation_actions_do_not_redirect_to_an_external_host
      comment = @reader.comments.create!(day: 1, body: 'Visible words')
      sign_in_as_admin

      patch "#{mount}/admin/comments/#{comment.id}/hide",
            params: { return_to: 'https://attacker.example/steal' }

      assert_redirected_to "#{mount}/admin/comments"
      assert comment.reload.hidden?
    end

    def test_hiding_a_reply_leaves_the_thread
      thought = @reader.comments.create!(day: 1, body: 'A reflection')
      reply = @reader.comments.create!(day: 1, body: 'An answer', parent: thought)
      sign_in_as_admin

      patch "#{mount}/admin/comments/#{reply.id}/hide"

      assert reply.reload.hidden?
      refute thought.reload.hidden?, 'hiding a reply must not hide what it answered'
    end

    def test_stale_comment_ids_redirect_with_an_alert_and_halt_each_action
      existing = @reader.comments.create!(day: 1, body: 'Still here')
      sign_in_as_admin

      [
        [:patch, "#{mount}/admin/comments/999999/hide"],
        [:patch, "#{mount}/admin/comments/999999/unhide"],
        [:delete, "#{mount}/admin/comments/999999"]
      ].each do |method, path|
        public_send(method, path)

        assert_redirected_to "#{mount}/admin/comments"
        assert_match(%r{Reflection not found}, flash[:alert].to_s)
        assert Bible270::Comment.exists?(existing.id)
      end
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
      assert_equal 3, response.body.scan(%r{name="passage_source"}).size
      assert_match(%r{value="bible_com" checked="checked"}, response.body)
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

    def test_an_admin_can_choose_bible_gateway_for_a_reader
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/version",
            params: { bible_version: 'LSB', passage_source: 'bible_gateway' }

      assert_equal 'bible_gateway', @reader.reload.passage_source
    end

    def test_an_admin_can_choose_blue_letter_bible_for_a_reader
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/version",
            params: { bible_version: 'LSB', passage_source: 'blue_letter_bible' }

      assert_equal 'blue_letter_bible', @reader.reload.passage_source
    end

    def test_an_admin_can_choose_bible_com_for_a_reader
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/version",
            params: { bible_version: 'LSB', passage_source: 'bible_com' }

      assert_equal 'bible_com', @reader.reload.passage_source
    end

    def test_an_admin_can_set_all_greek_with_bible_com
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/version",
            params: { bible_version: 'ALLGRK', passage_source: 'bible_com' }

      @reader.reload
      assert_equal 'ALLGRK', @reader.bible_version
      assert_equal 'bible_com', @reader.passage_source
    end

    def test_an_admin_cannot_set_an_unknown_passage_source
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/version",
            params: { bible_version: 'LSB', passage_source: 'unknown' }

      assert_equal 'bible_com', @reader.reload.passage_source
      assert_match(%r{not a reading-link source}, flash[:alert].to_s)
    end

    def test_omitting_the_source_returns_a_reader_to_bible_com
      @reader.update!(passage_source: 'blue_letter_bible')
      sign_in_as_admin

      patch "#{mount}/admin/readers/#{@reader.id}/version", params: { bible_version: 'LSB' }

      assert_equal 'bible_com', @reader.reload.passage_source
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

    def test_update_bible_version_handles_its_separate_stale_reader_lookup
      sign_in_as_admin

      patch "#{mount}/admin/readers/999999/version", params: { bible_version: 'KJV' }

      assert_redirected_to "#{mount}/admin"
      assert_match(%r{No such reader}, flash[:alert].to_s)
      assert_nil @reader.reload.bible_version
    end

    def test_an_ordinary_reader_cannot_set_someone_elses_translation
      sign_in_as(@reader)

      patch "#{mount}/admin/readers/#{@admin.id}/version", params: { bible_version: 'KJV' }

      assert_response :not_found
      assert_nil @admin.reload.bible_version
    end

    def test_a_visitor_cannot_set_a_readers_translation
      patch "#{mount}/admin/readers/#{@reader.id}/version", params: { bible_version: 'KJV' }

      assert_response :not_found
      assert_nil @reader.reload.bible_version
    end

    # The point of the setting: reading links open in their translation.
    def test_the_choice_uses_bible_com_on_the_readers_day_page
      sign_in_as_admin
      patch "#{mount}/admin/readers/#{@reader.id}/version", params: { bible_version: 'KJV' }
      reset!

      _record, raw = Bible270::SignInToken.issue!(@reader.email)
      get "#{mount}/sign_in/email/#{raw}"
      get "#{mount}/day/1"

      assert_match(%r{www\.bible\.com/bible/1/GEN\.1\.KJV}, response.body)
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

    def test_the_bible_com_choice_reaches_the_readers_day_page
      sign_in_as_admin
      patch "#{mount}/admin/readers/#{@reader.id}/version",
            params: { bible_version: 'KJV', passage_source: 'bible_com' }
      reset!

      _record, raw = Bible270::SignInToken.issue!(@reader.email)
      get "#{mount}/sign_in/email/#{raw}"
      get "#{mount}/day/1"

      assert_match(%r{www\.bible\.com/bible/1/GEN\.1\.KJV}, response.body)
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
