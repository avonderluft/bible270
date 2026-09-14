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
      assert_equal 'plain', comment.body_format
      assert_equal 'Reflection posted.', flash[:b270_interaction_status]
    end

    def test_the_reflection_form_has_a_reader_and_day_specific_draft_key
      sign_in_as(@reader)

      get "#{mount}/day/1"

      form = css_select('form[data-b270-draft="true"]').first
      key = form['data-b270-draft-key']
      assert_equal 'true', form['data-b270-submit']
      assert_equal 'Posting reflection…', form['data-b270-pending']
      assert_equal 'Reflection posted.', form['data-b270-success']
      assert_includes key, ":#{@reader.id}:1:root"
      refute_includes key, @reader.email
      assert_match(%r{Draft saved in this browser}, response.body)
      assert_match(%r{Bible270InteractionUI}, response.body)
      assert_select '[data-b270-draft-status][aria-live="polite"]'
      assert_select '#b270-interaction-status[role="status"]'
      assert_select "[data-b270-mention-composer][data-suggestions-url='#{mount}/mention-suggestions']" do
        assert_select 'label.b270-sr-only[for="b270-comment-body-new"]', text: 'Reflection'
        assert_select 'textarea#b270-comment-body-new[role="combobox"][aria-autocomplete="list"]' \
                      '[aria-expanded="false"][aria-controls="b270-mention-options-new"]'
        assert_select '#b270-mention-options-new[role="listbox"][hidden]'
        assert_select '[data-b270-mention-status][aria-live="polite"]'
        assert_select 'input[data-b270-body-format][value="markdown"]'
        assert_select "[data-b270-markdown-editor][data-b270-preview-url='#{mount}/comments/preview']"
        assert_select '[data-b270-editor-utilities][hidden]' do
          assert_select 'button[data-b270-formatting-toggle][aria-expanded="false"]', text: %r{Formatting}
          assert_select 'button[data-b270-preview-toggle][aria-pressed="false"]', text: 'Preview'
        end
        assert_select '[data-b270-formatting-drawer][aria-hidden="true"][inert]' do
          assert_select '[role="toolbar"][aria-label="Reflection formatting"]' do
            assert_select 'button[type="button"][data-b270-markdown-action]', count: 6
            assert_select '.b270-format-bold', text: 'B'
            assert_select '.b270-format-italic', text: 'I'
          end
        end
        assert_select '[data-b270-preview-panel][aria-live="polite"][hidden]'
      end
      assert_match(%r{Bible270MentionTypeahead}, response.body)
      assert_match(%r{Bible270MarkdownToolbar}, response.body)
      assert_match(%r{X-CSRF-Token}, response.body)
      assert_match(%r{b270PreviewUrl}, response.body)
      assert_includes response.body, 'const openEditors = new Set();'
      assert_includes response.body, 'function setFormattingOpen(editor, open, remember = true)'
      assert_includes response.body, 'drawer.inert = !open;'
      assert_includes response.body, 'dataset.b270DraftPosted === "true"'
      assert_includes response.body, 'event.key !== "Escape"'
      assert_includes response.body, 'previewing ? "Write" : "Preview"'
      assert_match(%r{selectionStart.*selectionEnd.*new Event\("input", \{ bubbles: true \}\)}m, response.body)
      assert_match(%r{ArrowDown.*ArrowUp.*Enter.*Escape}m, response.body)
    end

    def test_reply_drafts_are_scoped_to_the_parent_reflection
      parent = @other.comments.create!(day: 2, body: 'A question')
      sign_in_as(@reader)

      get "#{mount}/day/2", params: { reply_to: parent.id }

      assert_select "form[data-b270-draft-key$=':#{@reader.id}:2:#{parent.id}']" \
                    '[data-b270-pending="Posting reply…"][data-b270-success="Reply posted."]'
    end

    def test_a_signed_in_reader_can_preview_sanitized_markdown_without_saving
      @other.update!(first_name: 'Other', last_name: 'Reader')
      sign_in_as(@reader)

      post "#{mount}/comments/preview",
           params: {
             comment: {
               body: '**Grace @Other.Reader** [Guide](https://example.org/guide) ' \
                     'or https://example.org/news. <script>alert(1)</script>'
             }
           }

      assert_response :success
      assert_select 'strong', text: %r{Grace}
      assert_select 'a.b270-mention', text: '@Other.Reader'
      assert_select 'a[href="https://example.org/guide"]', text: 'Guide'
      assert_select 'a[href="https://example.org/news"]', text: 'https://example.org/news'
      refute_match(%r{<script\b}i, response.body)
      assert_equal 0, Bible270::Comment.count
    end

    def test_preview_keeps_lists_compact_when_the_source_has_blank_lines
      sign_in_as(@reader)

      post "#{mount}/comments/preview",
           params: { comment: { body: "- one\n\n- two\n\n1. one\n\n2. two" } }

      assert_response :success
      unordered_items = css_select('ul > li').map { |item| item.text.strip }
      ordered_items = css_select('ol > li').map { |item| item.text.strip }
      assert_equal %w[one two], unordered_items
      assert_equal %w[one two], ordered_items
      assert_select 'li > br', count: 0
      assert_select 'li > p', count: 0
    end

    def test_a_visitor_cannot_preview_markdown
      post "#{mount}/comments/preview", params: { comment: { body: '**Grace**' } }

      assert_response :redirect
      assert_equal 0, Bible270::Comment.count
    end

    def test_a_markdown_reflection_is_stored_and_rendered_in_a_turbo_response
      sign_in_as(@reader)

      post "#{mount}/day/1/comments",
           params: { comment: { body: '**Grace**', body_format: 'markdown' } },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      assert_response :success
      comment = Bible270::Comment.last
      assert_equal 'markdown', comment.body_format
      assert_select "turbo-stream[action='append'][target='comments']" do
        assert_select "#comment-#{comment.id} .b270-cbody strong", text: 'Grace'
      end
      assert_select "turbo-stream[action='replace'][target='new_comment_form']" do
        assert_select 'form[data-b270-draft-posted="true"]' do
          assert_select 'input[data-b270-body-format][value="markdown"]'
          assert_select '[data-b270-formatting-open="false"]'
        end
      end
    end

    def test_an_unknown_body_format_is_refused
      sign_in_as(@reader)

      post "#{mount}/day/1/comments",
           params: { comment: { body: 'Unsafe format', body_format: 'html' } }

      assert_equal 0, Bible270::Comment.count
      assert_match(%r{Body format is not included}, flash[:alert])
    end

    def test_a_failed_turbo_post_preserves_the_draft_contract
      sign_in_as(@reader)
      body = 'x' * 4001

      post "#{mount}/day/1/comments",
           params: { comment: { body: body, body_format: 'markdown' } },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      assert_response :unprocessable_entity
      assert_select 'form[data-b270-draft-errors="true"]' do
        assert_select 'input[data-b270-body-format][value="markdown"]'
        assert_select '[role="toolbar"][aria-label="Reflection formatting"]'
      end
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
