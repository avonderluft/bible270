# frozen_string_literal: true

require_relative 'support/admin_controller_test_case'

if RAILS_LOADED
  class AdminControllerTest < Bible270AdminControllerTestCase
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

    def test_an_admin_sees_a_reader
      sign_in_as_admin
      get "#{mount}/admin/readers/#{@reader.id}"

      assert_response :success
      assert_match(%r{R Reader}, response.body)
    end

    def test_reader_reflections_offer_edit_like_and_reply_controls_alongside_moderation
      reflection = @reader.comments.create!(day: 2, body: 'A reflection')
      reply = @reader.comments.create!(day: 2, body: 'A follow-up', parent: reflection)
      reflection.likes.create!(reader: @admin)
      sign_in_as_admin

      get "#{mount}/admin/readers/#{@reader.id}"

      [reflection, reply].each do |comment|
        assert_select "#comment-#{comment.id}", count: 1 do
          assert_select "a.b270-cedit[href='#{mount}/day/2?edit=#{comment.id}#comment-#{comment.id}']", text: 'edit'
          assert_select "form[action='#{mount}/comments/#{comment.id}/like'][data-turbo-stream='true']"
          assert_select "form[action='#{mount}/admin/comments/#{comment.id}/hide']"
        end
      end
      assert_select "#likes-#{reflection.id} .b270-likecount", text: '1'
      assert_select "#comment-#{reflection.id} a[href='#{mount}/day/2?reply_to=#{reflection.id}#new_comment_form']",
                    text: 'Reply'
      assert_select "#comment-#{reply.id} a", text: 'Reply', count: 0
      assert_select '#b270-interaction-status', count: 1
      assert_includes response.body, 'window.Bible270InteractionUI'

      post "#{mount}/comments/#{reflection.id}/like", params: { liked: '0' },
                                                      headers: { 'Accept' => 'text/vnd.turbo-stream.html' }
      assert_response :success
      assert_select "turbo-stream[action='replace'][target='likes-#{reflection.id}']"
      assert_empty reflection.likes.reload
    end

    def test_hidden_reader_reflections_keep_restore_without_unavailable_interaction_links
      comment = @reader.comments.create!(day: 2, body: 'Hidden reflection', approved: false)
      sign_in_as_admin

      get "#{mount}/admin/readers/#{@reader.id}"

      assert_select "#comment-#{comment.id}" do
        assert_select '.b270-badge', text: 'Hidden'
        assert_select "form[action='#{mount}/admin/comments/#{comment.id}/unhide']"
        assert_select '.b270-cedit, .b270-cactions', count: 0
      end
    end

    def test_reader_detail_panels_follow_the_requested_order
      sign_in_as_admin
      get "#{mount}/admin/readers/#{@reader.id}"

      headings = css_select('.b270-panel > h2').map { |heading| heading.text.strip }
      assert_equal ['Name and picture', 'Which translation they read', 'Theme', 'Email notifications',
                    'Where they are in the plan', 'Role: Reader', 'Status: Active', 'Completion animation'], headings.first(8)
      assert_equal 1, headings.count('Which translation they read')
      assert_equal 1, headings.count('Completions')
      assert_operator headings.index('Which translation they read'), :<, headings.index('Completions')
      assert_operator headings.index('Completions'), :<, headings.index('Remove')
    end

    def test_alumni_detail_panels_keep_the_same_order_without_schedule_controls
      sign_in_as_admin
      @reader.archive!
      get "#{mount}/admin/readers/#{@reader.id}"

      headings = css_select('.b270-panel > h2').map { |heading| heading.text.strip }
      assert_equal ['Name and picture', 'Which translation they read', 'Theme', 'Email notifications',
                    'Role: Reader', 'Status: Alumni', 'Completion animation'], headings.first(7)
      refute_includes headings, 'Where they are in the plan'
    end

    def test_reader_detail_email_is_a_mailto_link_with_provider_fallback
      sign_in_as_admin
      get "#{mount}/admin/readers/#{@reader.id}"
      assert_select "p.lede a[href='mailto:#{@reader.email}']", text: @reader.email

      @reader.update!(email: nil)
      get "#{mount}/admin/readers/#{@reader.id}"
      assert_select 'p.lede a[href^="mailto:"]', count: 0
      assert_select 'p.lede', text: %r{email}
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

    def test_an_admin_can_edit_someone_elses_reflection_without_changing_the_author
      comment = @reader.comments.create!(day: 1, body: 'Their words')
      sign_in_as_admin

      patch "#{mount}/comments/#{comment.id}", params: { comment: { body: 'Corrected words' } }

      assert_response :redirect
      assert_equal 'Corrected words', comment.reload.body
      assert_equal @reader.id, comment.reader_id
    end

    def test_an_admin_sees_and_can_open_the_edit_link_on_someone_elses_reflection
      comment = @reader.comments.create!(day: 1, body: 'Their words')
      sign_in_as_admin

      get "#{mount}/day/1"
      assert_match(%r{edit=#{comment.id}}, response.body)

      get "#{mount}/day/1", params: { edit: comment.id }
      assert_select "form[action='#{mount}/comments/#{comment.id}'].b270-editform" do
        assert_select 'textarea', text: 'Their words'
      end
    end

    # Deleting another person's reflection asks first; deleting your own does not.
    def test_removing_someone_elses_asks_for_confirmation
      @reader.comments.create!(day: 1, body: 'Theirs')
      sign_in_as_admin

      get "#{mount}/day/1"

      assert_match(%r{turbo-confirm}, response.body)
    end
  end
end
