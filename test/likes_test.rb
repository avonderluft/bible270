# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class LikesTest < ActionDispatch::IntegrationTest
    HEART = Bible270::Comment::HEART

    def setup
      needs_rails!
      clear_engine_tables!
      Bible270::Like.delete_all if defined?(Bible270::Like)

      @andrew = Bible270::Reader.create!(provider: 'email', uid: 'a@example.org', email: 'a@example.org',
                                         display_name: 'Andrew vonderLuft',
                                         first_name: 'Andrew', last_name: 'vonderLuft')
      @mary = Bible270::Reader.create!(provider: 'email', uid: 'm@example.org', email: 'm@example.org',
                                       display_name: 'Mary Smith', first_name: 'Mary', last_name: 'Smith')
      @thought = @andrew.comments.create!(day: 1, body: 'A reflection')
    end

    def mount = Bible270.config.mount_at.chomp('/')

    def sign_in_as(reader)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"
    end

    # ---- the model ---------------------------------------------------------

    def test_a_reader_can_like_a_reflection
      assert @thought.toggle_like!(@mary)

      assert_equal 1, @thought.likes.count
      assert @thought.liked_by?(@mary)
    end

    def test_liking_again_takes_it_back
      @thought.toggle_like!(@mary)

      refute @thought.toggle_like!(@mary)
      assert_equal 0, @thought.likes.count
      refute @thought.liked_by?(@mary)
    end

    # A double tap must not become two hearts.
    def test_the_same_reader_cannot_like_twice
      Bible270::Like.create!(reader: @mary, comment: @thought)
      second = Bible270::Like.new(reader: @mary, comment: @thought)

      refute second.valid?
    end

    def test_several_readers_each_add_a_heart
      @thought.toggle_like!(@mary)
      @thought.toggle_like!(@andrew)

      assert_equal 2, @thought.reload.likes.count
    end

    def test_a_visitor_has_liked_nothing
      refute @thought.liked_by?(nil)
    end

    def test_deleting_a_reflection_takes_its_likes
      @thought.toggle_like!(@mary)
      @thought.destroy

      assert_equal 0, Bible270::Like.count
    end

    def test_deleting_a_reader_takes_their_likes
      @thought.toggle_like!(@mary)
      @mary.destroy

      assert_equal 0, Bible270::Like.count
    end

    # ---- the page ----------------------------------------------------------

    def test_a_reflection_with_no_likes_shows_no_hearts
      get "#{mount}/day/1"

      assert_response :success
      refute_match(%r{class="b270-heart"}, response.body)
    end

    def test_each_like_is_another_heart
      @thought.toggle_like!(@mary)
      @thought.toggle_like!(@andrew)

      get "#{mount}/day/1"

      assert_equal 2, response.body.scan('class="b270-heart"').size
    end

    def test_a_heart_names_who_gave_it
      @thought.toggle_like!(@mary)

      get "#{mount}/day/1"

      assert_match(%r{class="b270-heart"\s+title="Mary Smith"}, response.body)
    end

    def test_the_hearts_appear_on_the_reflections_page_too
      @thought.toggle_like!(@mary)

      get "#{mount}/reflections"

      assert_match(%r{class="b270-heart"\s+title="Mary Smith"}, response.body)
    end

    # Your own like is the button, not a heart in the row as well: an admin with
    # one like was seeing two hearts, one naming them and one saying "you liked
    # this".
    def test_your_own_like_is_the_button_not_a_second_heart
      @thought.toggle_like!(@mary)
      sign_in_as(@mary)

      get "#{mount}/day/1"

      assert_equal 0, response.body.scan('class="b270-heart"').size, 'no separate heart for your own'
      assert_match(%r{tap to take it back}, response.body)
      assert_equal 1, response.body.scan(%r{❤️}).size, 'one heart altogether'
    end

    def test_other_peoples_hearts_still_show_beside_your_button
      @thought.toggle_like!(@mary)
      @thought.toggle_like!(@andrew)
      sign_in_as(@mary)

      get "#{mount}/day/1"

      assert_equal 1, response.body.scan('class="b270-heart"').size, "Andrew's, in the row"
      assert_match(%r{title="Andrew vonderLuft"}, response.body)
      assert_match(%r{tap to take it back}, response.body)
    end

    # Unliked is the same heart greyed by CSS, not a different character — so the
    # two states cannot differ in size, whatever the platform's emoji font does.
    def test_the_unliked_button_is_the_same_heart_greyed
      @thought.toggle_like!(@andrew)
      sign_in_as(@mary)

      get "#{mount}/day/1"

      assert_match(%r{class="b270-likebtn"[^>]*>}, response.body, 'not the liked variant')
      assert_match(%r{Like this reflection}, response.body)
      assert_equal 2, response.body.scan(%r{❤️}).size, "Andrew's heart and the grey button"
    end

    def test_the_liked_button_carries_the_liked_class
      @thought.toggle_like!(@mary)
      sign_in_as(@mary)

      get "#{mount}/day/1"

      assert_match(%r{class="b270-likebtn liked"}, response.body)
    end

    # The grey comes from CSS, so the rule has to exist for the button to be
    # distinguishable from a real like at all.
    def test_the_stylesheet_greys_the_unliked_button
      styles = File.read(File.expand_path('../app/views/bible270/shared/_styles.html.erb', __dir__))

      assert_match(/\.b270-likebtn\{[^}]*grayscale/, styles)
      assert_match(/\.b270-likebtn\.liked\{[^}]*filter:none/, styles)
    end

    # ---- liking through the page -------------------------------------------

    def test_a_visitor_cannot_like
      post "#{mount}/comments/#{@thought.id}/like"

      assert_equal 0, Bible270::Like.count
    end

    def test_a_reader_likes_and_unlikes
      sign_in_as(@mary)

      post "#{mount}/comments/#{@thought.id}/like"
      assert_equal 1, @thought.reload.likes.count

      post "#{mount}/comments/#{@thought.id}/like"
      assert_equal 0, @thought.reload.likes.count
    end

    def test_liking_something_that_is_gone
      sign_in_as(@mary)

      post "#{mount}/comments/999999/like"

      assert_response :not_found
    end

    def test_a_hidden_reflection_cannot_be_liked
      @thought.hide!
      sign_in_as(@mary)

      post "#{mount}/comments/#{@thought.id}/like"

      assert_response :not_found
      assert_equal 0, Bible270::Like.count
    end

    def test_a_reply_can_be_liked
      reply = @mary.comments.create!(day: 1, body: 'An answer', parent: @thought)
      sign_in_as(@andrew)

      post "#{mount}/comments/#{reply.id}/like"

      assert_equal 1, reply.reload.likes.count
    end

    def test_the_button_says_which_state_it_is_in
      sign_in_as(@mary)
      get "#{mount}/day/1"
      assert_match(%r{Like this reflection}, response.body)

      @thought.toggle_like!(@mary)
      get "#{mount}/day/1"
      assert_match(%r{tap to take it back}, response.body)
    end

    # 30 reflections must not mean 30 queries for hearts.
    def test_the_hearts_are_not_a_query_each
      5.times do |n|
        comment = @andrew.comments.create!(day: 1, body: "Reflection #{n}")
        comment.toggle_like!(@mary)
      end

      queries = 0
      counter = ->(*, payload) { queries += 1 if payload[:sql]&.include?('bible270_likes') }
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        get "#{mount}/day/1"
      end

      assert_operator queries, :<=, 2, "#{queries} like queries for one page is too many"
    end
  end
end
