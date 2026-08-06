# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class EditingReflectionsTest < ActionDispatch::IntegrationTest
    # The engine inlines its stylesheet, so every class name appears in every
    # response. Assertions about markup must match something the CSS cannot
    # contain — here, the class attribute itself.
    EDIT_FORM = %r{class="b270-form b270-editform"}

    def setup
      needs_rails!
      clear_engine_tables!
      @previous_from = Bible270.config.mailer_from
      Bible270.config.mailer_from = 'no-reply@example.org'

      @andrew = Bible270::Reader.create!(provider: 'email', uid: 'a@example.org', email: 'a@example.org',
                                         display_name: 'Andrew vonderLuft',
                                         first_name: 'Andrew', last_name: 'vonderLuft')
      @mary = Bible270::Reader.create!(provider: 'email', uid: 'm@example.org', email: 'm@example.org',
                                       display_name: 'Mary Smith', first_name: 'Mary', last_name: 'Smith')
      @mine = @mary.comments.create!(day: 1, body: 'First thoughts', track: 'ot')
      ActionMailer::Base.deliveries.clear
    end

    def teardown
      Bible270.config.mailer_from = @previous_from
    end

    def mount = Bible270.config.mount_at.chomp('/')

    def sign_in_as(reader)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"
    end

    # ---- who may edit ------------------------------------------------------

    def test_a_writer_can_change_their_own_reflection
      sign_in_as(@mary)
      patch "#{mount}/comments/#{@mine.id}", params: { comment: { body: 'Second thoughts' } }

      assert_equal 'Second thoughts', @mine.reload.body
    end

    def test_nobody_else_can
      sign_in_as(@andrew)
      patch "#{mount}/comments/#{@mine.id}", params: { comment: { body: 'Hijacked' } }

      assert_response :not_found
      assert_equal 'First thoughts', @mine.reload.body
    end

    def test_a_visitor_cannot
      patch "#{mount}/comments/#{@mine.id}", params: { comment: { body: 'Hijacked' } }

      assert_equal 'First thoughts', @mine.reload.body
    end

    # ---- what can change ---------------------------------------------------

    def test_the_track_can_be_changed
      sign_in_as(@mary)
      patch "#{mount}/comments/#{@mine.id}",
            params: { comment: { body: 'First thoughts', track: 'pp' } }

      assert_equal 'pp', @mine.reload.track
    end

    # Editing happens inline, so there is no standalone edit page to re-render:
    # the plain-HTML fallback redirects with an alert instead.
    def test_an_empty_body_is_refused
      sign_in_as(@mary)
      patch "#{mount}/comments/#{@mine.id}", params: { comment: { body: '   ' } }

      assert_response :redirect
      assert_equal 'First thoughts', @mine.reload.body
      refute_nil flash[:alert], 'the writer should be told why nothing changed'
    end

    # The path a browser actually takes, since the form is a turbo stream: the
    # form comes back with the error rather than the page navigating away.
    def test_a_rejected_edit_returns_the_form_over_turbo
      sign_in_as(@mary)
      patch "#{mount}/comments/#{@mine.id}",
            params: { comment: { body: '   ' } },
            headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      assert_response :success
      assert_match(%r{turbo-stream}, response.body)
      assert_match(%r{can&#39;t be blank|can't be blank}, response.body, 'the reason is shown')
      # The box holds what the reader typed, not the old text: discarding their
      # input on a validation failure would be worse. What must not change is the
      # stored reflection.
      assert_equal 'First thoughts', @mine.reload.body
    end

    # Moving a reflection to another day would take it out of the thread it
    # belongs to, so the day is not editable.
    def test_the_day_cannot_be_changed
      sign_in_as(@mary)
      patch "#{mount}/comments/#{@mine.id}", params: { comment: { body: 'Same', day: 9 } }

      assert_equal 1, @mine.reload.day
    end

    def test_a_reply_cannot_be_reparented_by_editing
      thought = @andrew.comments.create!(day: 1, body: 'A reflection')
      reply = @mary.comments.create!(day: 1, body: 'An answer', parent: thought)
      other = @andrew.comments.create!(day: 1, body: 'Another reflection')
      sign_in_as(@mary)

      patch "#{mount}/comments/#{reply.id}",
            params: { comment: { body: 'Changed', parent_id: other.id } }

      assert_equal thought.id, reply.reload.parent_id, 'parent_id is not editable'
    end

    # ---- the form on the page ---------------------------------------------

    # The link is a plain GET to the day page, so it works whether or not Turbo is
    # driving: an earlier version relied on Turbo intercepting the link, and did
    # nothing at all without it.
    def test_the_edit_link_opens_a_form_on_the_page
      sign_in_as(@mary)
      get "#{mount}/day/1", params: { edit: @mine.id }

      assert_response :success
      # Matched on the attribute, not the bare class name: the stylesheet is
      # inlined into every page, so /b270-editform/ is present whether or not a
      # form is — which made an earlier version of this pass with no form at all.
      assert_match(EDIT_FORM, response.body)
      assert_match(%r{First thoughts}, response.body, 'the words are in the box')
      assert_match(%r{Cancel}, response.body)
    end

    def test_the_edit_link_points_at_the_day_page
      sign_in_as(@mary)
      get "#{mount}/day/1"

      assert_match(%r{edit=#{@mine.id}}, response.body)
    end

    def test_no_form_opens_for_someone_elses_reflection
      theirs = @andrew.comments.create!(day: 1, body: 'Not yours')
      sign_in_as(@mary)

      get "#{mount}/day/1", params: { edit: theirs.id }

      assert_response :success
      refute_match(EDIT_FORM, response.body)
    end

    def test_a_reply_can_be_edited_in_place_too
      thought = @andrew.comments.create!(day: 1, body: 'A reflection')
      reply = @mary.comments.create!(day: 1, body: 'An answer', parent: thought)
      sign_in_as(@mary)

      get "#{mount}/day/1", params: { edit: reply.id }

      assert_response :success
      assert_match(EDIT_FORM, response.body)
    end

    def test_a_visitor_asking_to_edit_is_simply_ignored
      get "#{mount}/day/1", params: { edit: @mine.id }

      assert_response :success
      refute_match(EDIT_FORM, response.body)
    end

    # ---- the marker --------------------------------------------------------

    def test_a_fresh_reflection_is_not_marked_edited
      refute @mine.edited?

      get "#{mount}/day/1"
      refute_match(%r{>edited<}, response.body)
    end

    def test_an_edited_reflection_says_so
      @mine.update!(body: 'Revised', updated_at: 1.minute.from_now)

      assert @mine.reload.edited?

      get "#{mount}/day/1"
      assert_match(%r{>edited<}, response.body)
    end

    # ---- mentions ----------------------------------------------------------

    def test_adding_a_mention_by_editing_notifies_that_reader
      sign_in_as(@mary)
      patch "#{mount}/comments/#{@mine.id}", params: { comment: { body: 'What do you think @andrew' } }

      assert_equal 1, ActionMailer::Base.deliveries.size
      assert_equal [@andrew.email], ActionMailer::Base.deliveries.last.to
    end

    # Editing five times must not mail the same reader five times.
    def test_editing_again_does_not_notify_the_same_reader_twice
      sign_in_as(@mary)
      patch "#{mount}/comments/#{@mine.id}", params: { comment: { body: '@andrew first' } }
      ActionMailer::Base.deliveries.clear

      patch "#{mount}/comments/#{@mine.id}", params: { comment: { body: '@andrew second' } }

      assert_empty ActionMailer::Base.deliveries, 'already mentioned, so no second notice'
    end

    def test_editing_something_other_than_the_body_notifies_nobody
      mentioning = @mary.comments.create!(day: 1, body: 'Hello @andrew')
      ActionMailer::Base.deliveries.clear
      sign_in_as(@mary)

      patch "#{mount}/comments/#{mentioning.id}",
            params: { comment: { body: 'Hello @andrew', track: 'nt' } }

      assert_empty ActionMailer::Base.deliveries
    end

    # ---- the page ----------------------------------------------------------

    def test_the_edit_link_appears_only_on_your_own
      @andrew.comments.create!(day: 1, body: 'Not yours')
      sign_in_as(@mary)

      get "#{mount}/day/1"

      # The link is ?edit=<id> on the day page, not a /edit path — an earlier
      # version of this counted the wrong thing.
      assert_equal 1, response.body.scan(%r{edit=\d+}).size, 'one edit link, for Mary only'
      assert_match(%r{edit=#{@mine.id}}, response.body)
    end

    def test_a_visitor_sees_no_edit_links
      get "#{mount}/day/1"

      refute_match(%r{edit=\d+}, response.body)
    end
  end
end
