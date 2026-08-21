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

    def test_multiple_likes_show_one_heart_with_the_count_to_its_left
      @thought.toggle_like!(@mary)
      @thought.toggle_like!(@andrew)

      get "#{mount}/day/1"

      assert_equal 1, response.body.scan('class="b270-heart"').size
      assert_match(%r{class="b270-likecount">2</span>.*class="b270-heart"}m, response.body)
      assert_equal 1, response.body.scan(%r{❤️}).size
    end

    def test_hover_list_names_every_liker_on_separate_rows
      @thought.toggle_like!(@mary)
      @thought.toggle_like!(@andrew)

      get "#{mount}/day/1"

      assert_match(%r{class="b270-liker">Mary Smith</span>}, response.body)
      assert_match(%r{class="b270-liker">Andrew vonderLuft</span>}, response.body)
    end

    def test_the_like_summary_appears_on_the_reflections_page_too
      @thought.toggle_like!(@mary)

      get "#{mount}/reflections"

      assert_match(%r{class="b270-likecount">1</span>}, response.body)
      assert_match(%r{class="b270-liker">Mary Smith</span>}, response.body)
      assert_equal 1, response.body.scan(%r{❤️}).size
    end

    def test_your_own_like_is_in_the_count_and_hover_list
      @thought.toggle_like!(@mary)
      sign_in_as(@mary)

      get "#{mount}/day/1"

      assert_match(%r{class="b270-likecount">1</span>}, response.body)
      assert_match(%r{class="b270-liker">Mary Smith</span>}, response.body)
      assert_match(%r{Take back your like}, response.body)
      assert_equal 1, response.body.scan(%r{❤️}).size, 'one heart altogether'
    end

    def test_other_likers_share_the_count_and_hover_list_with_you
      @thought.toggle_like!(@mary)
      @thought.toggle_like!(@andrew)
      sign_in_as(@mary)

      get "#{mount}/day/1"

      assert_match(%r{class="b270-likecount">2</span>}, response.body)
      assert_match(%r{class="b270-liker">Mary Smith</span>}, response.body)
      assert_match(%r{class="b270-liker">Andrew vonderLuft</span>}, response.body)
      assert_equal 1, response.body.scan(%r{❤️}).size, 'one heart altogether'
    end

    def test_the_heart_stays_red_when_one_of_two_likers_removes_their_like
      @thought.toggle_like!(@mary)
      @thought.toggle_like!(@andrew)
      sign_in_as(@mary)

      post "#{mount}/comments/#{@thought.id}/like"
      get "#{mount}/day/1"

      assert_match(%r{class="b270-likecount">1</span>}, response.body)
      assert_match(%r{class="b270-likebtn liked"}, response.body)
      assert_match(%r{aria-label="Like this reflection"}, response.body)
      assert_equal 1, response.body.scan(%r{❤️}).size
    end

    def test_the_heart_is_grey_only_when_there_are_no_likes
      sign_in_as(@mary)

      get "#{mount}/day/1"

      assert_match(%r{class="b270-likebtn"[^>]*>}, response.body)
      refute_match(%r{class="b270-likebtn liked"}, response.body)
    end

    # The grey distinguishes an empty like count. The tooltip rows are
    # block-level so every liker appears on a separate line.
    def test_the_stylesheet_styles_the_button_and_liker_rows
      styles = File.read(File.expand_path('../app/views/bible270/shared/_styles.html.erb', __dir__))

      assert_match(/\.b270-likebtn\{[^}]*grayscale/, styles)
      assert_match(/\.b270-likebtn\.liked\{[^}]*filter:none/, styles)
      assert_match(/\.b270-liker\{[^}]*display:block/, styles)
      assert_match(%r{\.b270-likes:hover \.b270-liketooltip}, styles)
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

    def test_repeated_desired_states_do_not_reverse_a_like
      sign_in_as(@mary)

      2.times { post "#{mount}/comments/#{@thought.id}/like", params: { liked: '1' } }
      assert_equal 1, @thought.reload.likes.count

      2.times { post "#{mount}/comments/#{@thought.id}/like", params: { liked: '0' } }
      assert_equal 0, @thought.reload.likes.count
    end

    def test_an_invalid_desired_like_state_is_refused
      sign_in_as(@mary)

      post "#{mount}/comments/#{@thought.id}/like", params: { liked: 'perhaps' }

      assert_response :bad_request
      assert_equal 0, @thought.reload.likes.count
    end

    def test_the_like_form_describes_its_state_and_submission_feedback
      sign_in_as(@mary)

      get "#{mount}/day/1"

      assert_select 'form[data-b270-submit="true"][data-b270-pending="Saving like…"]' do
        assert_select 'input[type="hidden"][name="liked"][value="1"]'
        assert_select 'button[aria-label="Like this reflection"]'
      end
    end

    def test_html_likes_return_a_success_message
      sign_in_as(@mary)

      post "#{mount}/comments/#{@thought.id}/like", params: { liked: '1' }

      assert_response :redirect
      assert_equal 'Reflection liked.', flash[:b270_interaction_status]
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
      assert_match(%r{aria-label="Take back your like"}, response.body)
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
