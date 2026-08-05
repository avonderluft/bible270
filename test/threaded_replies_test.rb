# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class ThreadedRepliesTest < ActionDispatch::IntegrationTest
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
      @thought = @andrew.comments.create!(day: 1, body: 'My reflection')
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

    # ---- the model ---------------------------------------------------------

    def test_a_reply_belongs_to_its_parent
      reply = @mary.comments.create!(day: 1, body: 'Agreed', parent: @thought)

      assert reply.reply?
      assert_equal @thought.id, reply.parent_id
      assert_equal [reply.id], @thought.replies.pluck(:id)
    end

    # A tree would raise questions about indentation depth and what hiding a
    # middle node means; one level avoids all of it.
    def test_a_reply_cannot_be_replied_to
      reply = @mary.comments.create!(day: 1, body: 'Agreed', parent: @thought)
      second = @andrew.comments.build(day: 1, body: 'And so', parent: reply)

      refute second.valid?
      assert_includes second.errors[:parent].to_s, 'itself a reply'
    end

    def test_a_reply_must_be_on_the_same_day
      wrong = @mary.comments.build(day: 2, body: 'Elsewhere', parent: @thought)

      refute wrong.valid?
    end

    def test_replies_are_not_listed_as_reflections_of_their_own
      @mary.comments.create!(day: 1, body: 'Agreed', parent: @thought)

      assert_equal [@thought.id], Bible270::Comment.for_day(1).pluck(:id),
                   'a reply appears under its parent, not again at the top level'
    end

    def test_deleting_a_reflection_takes_its_replies
      @mary.comments.create!(day: 1, body: 'Agreed', parent: @thought)
      @thought.destroy

      assert_equal 0, Bible270::Comment.count
    end

    def test_a_hidden_reply_is_not_shown
      reply = @mary.comments.create!(day: 1, body: 'Questionable', parent: @thought)
      reply.hide!

      assert_empty @thought.visible_replies
    end

    # ---- the page ----------------------------------------------------------

    def test_a_reply_renders_indented_under_its_parent
      @mary.comments.create!(day: 1, body: 'Quite so', parent: @thought)
      get "#{mount}/day/1"

      assert_response :success
      assert_match(%r{b270-reply}, response.body)
      assert_operator response.body.index('My reflection'), :<, response.body.index('Quite so'),
                      'the reply should follow the reflection it answers'
    end

    def test_a_reply_sits_inside_its_parents_replies_container
      reply = @mary.comments.create!(day: 1, body: 'Quite so', parent: @thought)
      get "#{mount}/day/1"

      container = response.body.index(%(id="replies-#{@thought.id}"))
      refute_nil container
      assert_operator container, :<, response.body.index(%(id="comment-#{reply.id}"))
    end

    def test_replying_posts_a_reply_not_a_reflection
      sign_in_as(@mary)
      post "#{mount}/day/1/comments",
           params: { comment: { body: '@andrew yes', parent_id: @thought.id } }

      created = Bible270::Comment.order(:id).last
      assert created.reply?
      assert_equal @thought.id, created.parent_id
      assert_equal 1, Bible270::Comment.for_day(1).count, 'still one thread'
    end

    def test_the_reply_form_says_who_is_being_answered
      sign_in_as(@mary)
      get "#{mount}/day/1", params: { reply_to: @thought.id }

      assert_response :success
      assert_match(%r{Replying to}, response.body)
      assert_match(%r{Andrew vonderLuft}, response.body)
      assert_match(%r{@andrew}, response.body, 'and prefills the mention')
    end

    def test_a_reply_still_notifies_the_author
      sign_in_as(@mary)
      post "#{mount}/day/1/comments",
           params: { comment: { body: '@andrew yes', parent_id: @thought.id } }

      assert_equal 1, ActionMailer::Base.deliveries.size
      assert_equal [@andrew.email], ActionMailer::Base.deliveries.last.to
    end

    def test_a_reply_offers_no_reply_link_of_its_own
      @mary.comments.create!(day: 1, body: 'Quite so', parent: @thought)
      sign_in_as(@andrew)

      get "#{mount}/day/1"

      # Andrew wrote the reflection, so no Reply on it; the reply is Mary's but is
      # one level down, so it must not offer one either.
      assert_equal 0, response.body.scan('reply_to=').size
    end

    def test_replying_to_a_reply_by_url_is_refused
      reply = @mary.comments.create!(day: 1, body: 'Quite so', parent: @thought)
      sign_in_as(@andrew)

      get "#{mount}/day/1", params: { reply_to: reply.id }

      assert_response :success
      refute_match(%r{Replying to}, response.body, 'a reply cannot be answered')
    end
  end
end
