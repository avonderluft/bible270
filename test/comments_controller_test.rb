# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class CommentsControllerTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @reader = Bible270::Reader.create!(provider: 'email', uid: 'r@example.org',
                                         email: 'r@example.org', display_name: 'R Reader')
      @other = Bible270::Reader.create!(provider: 'email', uid: 'o@example.org',
                                        email: 'o@example.org', display_name: 'Other Reader')
    end

    def mount = Bible270.config.mount_at.chomp('/')

    def sign_in_as(reader)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"
    end

    def test_a_visitor_cannot_post_a_reflection
      post "#{mount}/day/1/comments", params: { comment: { body: 'Hello' } }

      assert_equal 0, Bible270::Comment.count
    end

    def test_a_reader_can_post_a_reflection
      sign_in_as(@reader)
      post "#{mount}/day/1/comments", params: { comment: { body: 'A thought on Genesis' } }

      assert_equal 1, Bible270::Comment.count
      comment = Bible270::Comment.last
      assert_equal @reader.id, comment.reader_id
      assert_equal 1, comment.day
      assert_equal 'A thought on Genesis', comment.body
    end

    def test_the_reflection_form_has_a_reader_and_day_specific_draft_key
      sign_in_as(@reader)

      get "#{mount}/day/1"

      form = css_select('form[data-b270-draft="true"]').first
      key = form['data-b270-draft-key']
      assert_includes key, ":#{@reader.id}:1:root"
      refute_includes key, @reader.email
      assert_match(%r{Draft saved in this browser}, response.body)
      assert_select '[data-b270-draft-status][aria-live="polite"]'
    end

    def test_reply_drafts_are_scoped_to_the_parent_reflection
      parent = @other.comments.create!(day: 2, body: 'A question')
      sign_in_as(@reader)

      get "#{mount}/day/2", params: { reply_to: parent.id }

      assert_select "form[data-b270-draft-key$=':#{@reader.id}:2:#{parent.id}']"
    end

    def test_a_failed_turbo_post_preserves_the_draft_contract
      sign_in_as(@reader)
      body = 'x' * 4001

      post "#{mount}/day/1/comments",
           params: { comment: { body: body } },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      assert_response :unprocessable_entity
      assert_select 'form[data-b270-draft-errors="true"]'
      assert_includes response.body, body
      assert_equal 0, Bible270::Comment.count
    end

    # The form's "the whole day" option submits an empty string, which used to be
    # rejected as "Track is not included in the list".
    def test_a_reflection_about_the_whole_day_is_accepted
      sign_in_as(@reader)
      post "#{mount}/day/1/comments", params: { comment: { body: 'On the day', track: '' } }

      assert_equal 1, Bible270::Comment.count
      assert_nil Bible270::Comment.last.track, 'blank should be stored as no track'
    end

    def test_a_reflection_about_one_track_keeps_it
      sign_in_as(@reader)
      post "#{mount}/day/1/comments", params: { comment: { body: 'On the psalm', track: 'pp' } }

      assert_equal 'pp', Bible270::Comment.last.track
    end

    def test_an_empty_reflection_is_refused
      sign_in_as(@reader)
      post "#{mount}/day/1/comments", params: { comment: { body: '   ' } }

      assert_equal 0, Bible270::Comment.count
    end

    def test_a_day_outside_the_plan_is_refused
      sign_in_as(@reader)
      post "#{mount}/day/999/comments", params: { comment: { body: 'Nowhere' } }

      assert_response :bad_request
      assert_equal 0, Bible270::Comment.count
    end

    def test_a_reader_can_delete_their_own_reflection
      sign_in_as(@reader)
      post "#{mount}/day/1/comments", params: { comment: { body: 'Mine' } }
      comment = Bible270::Comment.last

      delete "#{mount}/comments/#{comment.id}"

      assert_equal 0, Bible270::Comment.count
    end

    def test_a_reader_cannot_delete_someone_elses
      theirs = @other.comments.create!(day: 1, body: 'Theirs')
      sign_in_as(@reader)

      delete "#{mount}/comments/#{theirs.id}"

      assert_response :not_found
      assert Bible270::Comment.exists?(theirs.id), 'it should still be there'
    end

    # Only admins get that power; an ordinary reader still cannot.
    def test_an_ordinary_reader_still_cannot_delete_someone_elses
      theirs = @other.comments.create!(day: 1, body: 'Theirs')
      sign_in_as(@reader)

      delete "#{mount}/comments/#{theirs.id}"

      assert_response :not_found
      assert Bible270::Comment.exists?(theirs.id)
    end

    def test_an_ordinary_reader_sees_no_delete_on_someone_elses
      @other.comments.create!(day: 1, body: 'Theirs')
      sign_in_as(@reader)

      get "#{mount}/day/1"

      refute_match(%r{class="b270-cdel"}, response.body)
    end

    def test_hidden_reflections_do_not_appear_on_the_day
      visible = @reader.comments.create!(day: 1, body: 'Visible one')
      hidden  = @reader.comments.create!(day: 1, body: 'Hidden one')
      hidden.hide!

      get "#{mount}/day/1"

      assert_response :success
      assert_match(%r{Visible one}, response.body)
      refute_match(%r{Hidden one}, response.body)
      assert_equal 2, Bible270::Comment.count, 'hiding keeps the words, it does not delete them'
      assert_equal visible.id, Bible270::Comment.for_day(1).first.id
    end
  end
end
