# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class AdminControllerTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_admins = Bible270.config.admin_emails
      @admin = Bible270::Reader.create!(provider: 'email', uid: 'boss@example.org',
                                        email: 'boss@example.org', display_name: 'The Boss')
      @reader = Bible270::Reader.create!(provider: 'email', uid: 'r@example.org',
                                         email: 'r@example.org', display_name: 'R Reader',
                                         first_name: 'R', last_name: 'Reader')
    end

    def teardown
      Bible270.config.admin_emails = @previous_admins
      Bible270::Setting.open_enrollment!
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
      assert_equal 42, Bible270::Plan.day_for(Date.current, @reader.started_on)
    end

    # allow_reader_start_date governs what a *reader* may change; it must not
    # block an admin acting on their behalf.
    def test_an_admin_can_set_a_date_even_when_readers_cannot
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
