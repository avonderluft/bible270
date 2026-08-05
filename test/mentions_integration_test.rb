# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class MentionsIntegrationTest < ActionDispatch::IntegrationTest
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
      ActionMailer::Base.deliveries.clear
    end

    def teardown
      Bible270.config.mailer_from = @previous_from
      Bible270.config.mention_notifications = true
    end

    def mount = Bible270.config.mount_at.chomp('/')

    def sign_in_as(reader)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"
    end

    def post_reflection(body, as:)
      sign_in_as(as)
      post "#{mount}/day/1/comments", params: { comment: { body: body } }
    end

    def test_a_mention_emails_the_person_named
      post_reflection('Good point @Andrew', as: @mary)

      assert_equal 1, ActionMailer::Base.deliveries.size
      mail = ActionMailer::Base.deliveries.last
      assert_equal [@andrew.email], mail.to
      assert_match(%r{Mary Smith}, mail.subject)
    end

    def test_mentioning_yourself_sends_nothing
      post_reflection('Note to self @Mary', as: @mary)

      assert_empty ActionMailer::Base.deliveries
    end

    def test_an_unknown_handle_sends_nothing
      post_reflection('Hello @Nobody', as: @mary)

      assert_empty ActionMailer::Base.deliveries
      assert_equal 1, Bible270::Comment.count, 'the reflection is still posted'
    end

    # Two Andrews means the short handle is ambiguous, so nobody is mailed.
    def test_an_ambiguous_handle_sends_nothing
      Bible270::Reader.create!(provider: 'email', uid: 'a2@example.org', email: 'a2@example.org',
                               display_name: 'Andrew Miller', first_name: 'Andrew', last_name: 'Miller')

      post_reflection('Which one @Andrew', as: @mary)

      assert_empty ActionMailer::Base.deliveries
    end

    def test_the_dotted_handle_disambiguates
      Bible270::Reader.create!(provider: 'email', uid: 'a2@example.org', email: 'a2@example.org',
                               display_name: 'Andrew Miller', first_name: 'Andrew', last_name: 'Miller')

      post_reflection('You specifically @Andrew.vonderLuft', as: @mary)

      assert_equal 1, ActionMailer::Base.deliveries.size
      assert_equal [@andrew.email], ActionMailer::Base.deliveries.last.to
    end

    def test_a_reader_can_opt_out
      @andrew.update!(notify_on_mention: false)

      post_reflection('Are you there @Andrew', as: @mary)

      assert_empty ActionMailer::Base.deliveries
    end

    def test_the_feature_can_be_switched_off_entirely
      Bible270.config.mention_notifications = false

      post_reflection('Hello @Andrew', as: @mary)

      assert_empty ActionMailer::Base.deliveries
    end

    def test_several_people_can_be_mentioned_at_once
      post_reflection('Both of you @Andrew and @Mary', as: @andrew)

      assert_equal 1, ActionMailer::Base.deliveries.size, 'Mary only; Andrew wrote it'
      assert_equal [@mary.email], ActionMailer::Base.deliveries.last.to
    end

    # ---- the page ----------------------------------------------------------

    def test_a_mention_is_rendered_as_a_link
      @mary.comments.create!(day: 1, body: 'Good point @Andrew')
      get "#{mount}/day/1"

      assert_response :success
      assert_match(%r{<a[^>]*b270-mention[^>]*>@Andrew</a>}, response.body)
    end

    def test_an_unresolved_mention_stays_plain_text
      @mary.comments.create!(day: 1, body: 'Hello @Nobody')
      get "#{mount}/day/1"

      assert_match(%r{@Nobody}, response.body)
      refute_match(%r{<a[^>]*b270-mention[^>]*>@Nobody</a>}, response.body)
    end

    def test_a_reflection_cannot_smuggle_markup
      @mary.comments.create!(day: 1, body: '<script>alert(1)</script> @Andrew')
      get "#{mount}/day/1"

      refute_match(%r{<script>alert}, response.body, 'the body must be escaped')
      assert_match(%r{&lt;script&gt;}, response.body)
    end

    def test_replying_prefills_the_handle
      comment = @andrew.comments.create!(day: 1, body: 'My thought')
      sign_in_as(@mary)

      get "#{mount}/day/1", params: { reply_to: comment.id }

      assert_response :success
      assert_match(%r{@andrew}, response.body, 'the form should be prefilled with the handle')
    end

    def test_the_reply_link_is_offered_on_other_peoples_reflections
      @andrew.comments.create!(day: 1, body: 'My thought')
      sign_in_as(@mary)

      get "#{mount}/day/1"

      assert_match(%r{reply_to=}, response.body)
    end

    def test_no_reply_link_on_your_own
      @mary.comments.create!(day: 1, body: 'Mine')
      sign_in_as(@mary)

      get "#{mount}/day/1"

      refute_match(%r{reply_to=}, response.body)
    end
  end
end
