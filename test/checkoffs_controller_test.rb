# frozen_string_literal: true

require 'test_helper'
require 'bible270/scripture_frames'

if RAILS_LOADED
  class CheckoffsControllerTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @reader = Bible270::Reader.create!(provider: 'email', uid: 'r@example.org',
                                         email: 'r@example.org', display_name: 'R Reader')
    end

    def mount = Bible270.config.mount_at.chomp('/')

    # Signing in through the real flow, so the session is established the way a
    # reader's would be.
    def sign_in_as(reader)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"
    end

    def test_a_visitor_cannot_check_anything_off
      post "#{mount}/day/1/toggle/nt"

      assert_equal 0, Bible270::Checkoff.count
      assert_response :redirect
    end

    def test_signing_in_then_toggling_records_it
      sign_in_as(@reader)
      post "#{mount}/day/1/toggle/nt"

      assert_equal 1, @reader.checkoffs.count
      assert @reader.checkoffs.exists?(day: 1, track: 'nt')
    end

    def test_toggling_twice_removes_it
      sign_in_as(@reader)
      post "#{mount}/day/1/toggle/nt"
      post "#{mount}/day/1/toggle/nt"

      assert_equal 0, @reader.checkoffs.count
    end

    def test_repeated_desired_states_do_not_reverse_a_checkoff
      sign_in_as(@reader)

      2.times { post "#{mount}/day/1/toggle/nt", params: { checked: '1' } }
      assert_equal 1, @reader.checkoffs.where(day: 1, track: 'nt').count

      2.times { post "#{mount}/day/1/toggle/nt", params: { checked: '0' } }
      assert_equal 0, @reader.checkoffs.where(day: 1, track: 'nt').count
    end

    def test_an_invalid_desired_checkoff_state_is_refused
      sign_in_as(@reader)

      post "#{mount}/day/1/toggle/nt", params: { checked: 'perhaps' }

      assert_response :bad_request
      assert_equal 0, @reader.checkoffs.count
    end

    def test_checkoff_forms_describe_their_state_and_submission_feedback
      sign_in_as(@reader)

      get "#{mount}/day/1"

      assert_select 'form[data-b270-submit="true"][data-b270-checkoff="true"][data-b270-pending="Saving reading…"]' do
        assert_select 'input[type="hidden"][name="checked"][value="1"]'
        assert_select 'button[type="submit"]'
      end
      assert_select '#b270-interaction-status[role="status"][aria-live="polite"]'
      assert_select "script[data-refresh-path='#{mount}/session/refresh']"
      assert_match(%r{Bible270InteractionUI}, response.body)
      assert_match(%r{visibilitychange}, response.body)
      assert_match(%r{X-CSRF-Token}, response.body)
      assert_match(%r{requestSubmit}, response.body)
      assert_match(%r{X-Bible270-Refresh-Session}, response.body)
      assert_match(%r{statusCode === 422}, response.body)
      assert_match(%r{contentType\.includes\("text/html"\)}, response.body)
      assert_match(%r{target\.closest\("form"\)}, response.body)
      assert_match(%r{b270RetriedAfterStaleSession}, response.body)
      assert_match(%r{window\.location\.reload}, response.body)
      assert_match(%r{completedDay}, response.body)
      assert_select '[data-b270-completion-dove-template]', count: 0
      assert_match(%r{width:min\(94vw,112vh\)}, response.body)
      assert_match(%r{color-scheme:only light}, response.body)
      assert_match(%r{forced-color-adjust:none}, response.body)
      assert_match(%r{100%\{opacity:1;visibility:visible;.*scale\(1\.15\)}, response.body)
      assert_match(%r{\.b270-completion-dove\{position:absolute;[^\}]*top:50%;left:50%}, response.body)
      assert_match(%r{\.b270-completion\.is-visible\.is-flying\{animation:b270-completion-exit}, response.body)
      refute_match(%r{left:115vw}, response.body)
      assert_match(%r{sessionStorage\.getItem}, response.body)
      assert_match(%r{prefers-reduced-motion: reduce}, response.body)
      assert_match(%r{turbo:before-cache}, response.body)
      assert_match(%r{animationend}, response.body)
    end

    def test_only_the_checkoff_that_completes_a_day_marks_the_completion_effect
      sign_in_as(@reader)
      @reader.mark_day_complete!(1)
      @reader.checkoffs.find_by!(day: 1, track: 'nt', part: 0).destroy!

      frame = completion_frame
      Bible270::ScriptureFrames.stub(:random, frame) do
        post "#{mount}/day/1/toggle/nt/0",
             params: { checked: '1' }, headers: turbo_stream_headers
      end

      assert_response :success
      assert_select '[data-b270-day-just-completed="true"][data-b270-day="1"]', count: 1
      completion_event_id = @reader.reload.checkoffs.where(day: 1).maximum(:id)
      assert_select 'turbo-stream[action="replace"][target="day_progress_1"]' do
        assert_completion_root(completion_event_id) do
          assert_completion_frame(frame)
          assert_select "div[data-b270-completion-dove][aria-hidden='true'][data-b270-day='1']" \
                        "[data-b270-completion-event='#{completion_event_id}'][data-turbo-temporary]", count: 1 do
            assert_select '> svg[viewBox="0 0 260 200"][width="260"][height="200"]', count: 1
            assert_select '.b270-dove-feathers', count: 0
            assert_select 'path.b270-dove-beak', count: 1
            assert_select '.b270-dove-light-center[stop-color="#fff"]', count: 1
          end
        end
      end

      Bible270::ScriptureFrames.stub(:random, -> { flunk 'a repeated checkoff must not select a frame' }) do
        post "#{mount}/day/1/toggle/nt/0",
             params: { checked: '1' }, headers: turbo_stream_headers
      end

      assert_response :success
      assert_select '[data-b270-day-just-completed]', count: 0
      assert_select '[data-b270-completion]', count: 0
      assert_select '[data-b270-completion-dove]', count: 0
    end

    def test_an_admin_can_disable_the_completion_dove_without_hiding_completion_status
      @reader.update!(completion_dove_disabled: true)
      @reader.mark_day_complete!(1)
      @reader.checkoffs.find_by!(day: 1, track: 'nt', part: 0).destroy!
      sign_in_as(@reader)

      frame = completion_frame
      Bible270::ScriptureFrames.stub(:random, frame) do
        post "#{mount}/day/1/toggle/nt/0",
             params: { checked: '1' }, headers: turbo_stream_headers
      end

      assert_response :success
      assert_select '[data-b270-day-just-completed="true"][data-b270-day="1"]', count: 1
      assert_select 'turbo-stream[action="replace"][target="day_progress_1"]' do
        assert_completion_root(@reader.reload.checkoffs.where(day: 1).maximum(:id)) do
          assert_completion_frame(frame)
          assert_select '[data-b270-completion-dove]', count: 0
        end
        assert_select '.b270-day-complete', text: %r{Day 1 complete}
      end
      assert_select '[data-b270-completion-dove]', count: 0
    end

    def test_a_final_html_checkoff_redirects_to_the_completion_sequence_without_a_success_message
      sign_in_as(@reader)
      @reader.mark_day_complete!(1)
      @reader.checkoffs.find_by!(day: 1, track: 'nt', part: 0).destroy!

      post "#{mount}/day/1/toggle/nt/0", params: { checked: '1' }

      assert_response :redirect
      assert_nil flash[:b270_interaction_status]
      assert_equal 1, flash[:b270_day_just_completed]
      assert_equal @reader.reload.checkoffs.where(day: 1).maximum(:id), flash[:b270_completion_event_id]

      frame = completion_frame
      Bible270::ScriptureFrames.stub(:random, frame) { follow_redirect! }

      assert_response :success
      assert_select '#day_progress_1' do
        assert_completion_root(@reader.checkoffs.where(day: 1).maximum(:id)) do
          assert_completion_frame(frame)
        end
      end
      assert_select '#day_progress_1 div[data-b270-completion-dove][data-b270-day="1"] > svg', count: 1
      assert_select '#b270-interaction-status', text: '', count: 1

      Bible270::ScriptureFrames.stub(:random, -> { flunk 'an ordinary revisit must not select a frame' }) do
        get "#{mount}/day/1"
      end

      assert_response :success
      assert_select '#day_progress_1 .b270-day-complete', text: %r{Day 1 complete}
      assert_select '[data-b270-day-just-completed]', count: 0
      assert_select '[data-b270-completion]', count: 0
      assert_select '[data-b270-completion-dove]', count: 0
    end

    def test_a_final_html_checkoff_still_shows_the_frame_when_the_dove_is_disabled
      @reader.update!(completion_dove_disabled: true)
      @reader.mark_day_complete!(1)
      @reader.checkoffs.find_by!(day: 1, track: 'nt', part: 0).destroy!
      sign_in_as(@reader)
      frame = completion_frame

      Bible270::ScriptureFrames.stub(:random, frame) do
        post "#{mount}/day/1/toggle/nt/0", params: { checked: '1' }
        assert_response :redirect
        assert_nil flash[:b270_interaction_status]
        follow_redirect!
      end

      assert_response :success
      assert_select '#day_progress_1' do
        assert_completion_root(@reader.reload.checkoffs.where(day: 1).maximum(:id)) do
          assert_completion_frame(frame)
        end
        assert_select '.b270-day-complete', text: %r{Day 1 complete}
      end
      assert_select '[data-b270-completion-dove]', count: 0
    end

    def test_incomplete_requests_do_not_select_or_render_a_completion_frame
      sign_in_as(@reader)

      Bible270::ScriptureFrames.stub(:random, -> { flunk 'an incomplete day must not select a frame' }) do
        get "#{mount}/day/1"
        assert_response :success
        assert_select '[data-b270-completion]', count: 0

        post "#{mount}/day/1/toggle/nt/0", params: { checked: '1' }
        assert_response :redirect
        follow_redirect!
        assert_response :success
        assert_select '[data-b270-completion]', count: 0
        assert_select '[data-b270-completion-dove]', count: 0

        post "#{mount}/day/1/toggle/pp/0", params: { checked: '1' }, headers: turbo_stream_headers
        assert_response :success
        assert_select 'turbo-stream[action="replace"][target="day_progress_1"]' do
          assert_select '[data-b270-day-just-completed]', count: 0
          assert_select '[data-b270-completion]', count: 0
          assert_select '[data-b270-completion-frame]', count: 0
          assert_select '[data-b270-completion-dove]', count: 0
        end
      end

      refute @reader.reload_progress.day_complete?(1)
    end

    def test_the_server_selected_enabled_custom_frame_is_inline_escaped_and_credited
      record = Bible270::ScriptureFrame.create!(
        reference: '<b>Example 1:2</b>', translation: 'NKJV',
        text: "<script>alert('sample')</script>\nA & B.", attribution: 'Forged credit.', enabled: true
      )
      assert record.enabled?
      frame = Bible270::ScriptureFrames::Entry.new(
        id: "custom:#{record.id}", reference: record.reference, translation: record.translation,
        text: record.text, attribution: record.attribution
      )
      @reader.mark_day_complete!(1)
      @reader.checkoffs.find_by!(day: 1, track: 'nt', part: 0).destroy!
      sign_in_as(@reader)
      selections = 0

      Bible270::ScriptureFrames.stub(:random, -> {
        selections += 1
        frame
      }) do
        post "#{mount}/day/1/toggle/nt/0", params: { checked: '1' }, headers: turbo_stream_headers
      end

      assert_response :success
      assert_equal 1, selections, 'the response must select its frame server-side exactly once'
      assert_equal 'NKJV © 1982 Thomas Nelson.', frame.attribution
      assert_select 'turbo-stream[action="replace"][target="day_progress_1"]' do
        assert_completion_root(@reader.reload.checkoffs.where(day: 1).maximum(:id)) do
          assert_completion_frame(frame)
          assert_select 'script, [data-b270-scripture-art] b', count: 0
        end
      end
      refute_includes response.body, "<script>alert('sample')</script>"
      refute_includes response.body, 'Forged credit.'
    end

    def test_a_nil_frame_keeps_the_completion_root_and_original_dove_fallback
      @reader.mark_day_complete!(1)
      @reader.checkoffs.find_by!(day: 1, track: 'nt', part: 0).destroy!
      sign_in_as(@reader)

      Bible270::ScriptureFrames.stub(:random, nil) do
        post "#{mount}/day/1/toggle/nt/0", params: { checked: '1' }, headers: turbo_stream_headers
      end

      assert_response :success
      assert_select 'turbo-stream[action="replace"][target="day_progress_1"]' do
        assert_completion_root(@reader.reload.checkoffs.where(day: 1).maximum(:id)) do
          assert_select '[data-b270-completion-frame], .b270-completion-frame', count: 0
          assert_select '[data-b270-scripture-art]', count: 0
          assert_select 'div[data-b270-completion-dove] > svg', count: 1
        end
        assert_select '.b270-day-complete', text: %r{Day 1 complete}
      end
    end

    def test_an_empty_pool_with_the_dove_disabled_still_shows_completion_status
      Bible270::ScriptureFrame.create!(reference: 'Disabled example', text: 'Hidden sample.', enabled: false)
      @reader.update!(completion_dove_disabled: true)
      @reader.mark_day_complete!(1)
      @reader.checkoffs.find_by!(day: 1, track: 'nt', part: 0).destroy!
      sign_in_as(@reader)

      Bible270::ScriptureFrames.stub(:defaults, []) do
        post "#{mount}/day/1/toggle/nt/0", params: { checked: '1' }, headers: turbo_stream_headers
      end

      assert_response :success
      assert_select 'turbo-stream[action="replace"][target="day_progress_1"]' do
        assert_completion_root(@reader.reload.checkoffs.where(day: 1).maximum(:id)) do
          assert_select '[data-b270-completion-frame], .b270-completion-frame', count: 0
          assert_select '[data-b270-scripture-art]', count: 0
          assert_select '[data-b270-completion-dove]', count: 0
        end
        assert_select '.b270-day-complete', text: %r{Day 1 complete}
      end
    end

    def test_html_checkoffs_return_a_success_message
      sign_in_as(@reader)

      post "#{mount}/day/1/toggle/nt", params: { checked: '1' }

      assert_response :redirect
      assert_equal 'Reading marked read.', flash[:b270_interaction_status]
    end

    def test_a_day_outside_the_plan_is_refused
      sign_in_as(@reader)
      post "#{mount}/day/999/toggle/nt"

      assert_response :bad_request
      assert_equal 0, Bible270::Checkoff.count
    end

    def test_an_unknown_track_is_refused
      sign_in_as(@reader)
      post "#{mount}/day/1/toggle/xx"

      assert_response :bad_request
      assert_equal 0, Bible270::Checkoff.count
    end

    def test_each_chapter_toggles_independently
      needs_chapter_parts!
      sign_in_as(@reader)

      post "#{mount}/day/1/toggle/ot/1"

      assert_equal [1], @reader.checkoffs.where(track: 'ot').pluck(:part),
                   'the second chapter should be ticked, not the first'
      refute @reader.reload_progress.read?(1, 'ot'), 'one of three chapters is not the whole track'
    end

    def test_a_chapter_beyond_the_reading_is_refused
      needs_chapter_parts!
      sign_in_as(@reader)

      post "#{mount}/day/1/toggle/ot/9"

      assert_response :bad_request
      assert_equal 0, Bible270::Checkoff.count
    end

    def test_checking_off_starts_an_undated_reader
      # ensure_started! only applies when personal calendars are enabled and
      # there is no community-wide date.
      skip 'a community start date is set' if Bible270::Setting.run_start_date
      skip 'personal calendars are disabled' unless Bible270.config.allow_reader_start_date

      sign_in_as(@reader)
      post "#{mount}/day/1/toggle/nt"

      refute_nil @reader.reload.started_on, 'the first check-off should start their clock'
    end

    def test_a_shared_run_override_prevents_a_personal_date_from_being_stamped
      Bible270::Setting.set_run_start_date!(Bible270.today - 4)
      sign_in_as(@reader)

      post "#{mount}/day/1/toggle/nt"

      assert_nil @reader.reload.started_on
      assert_equal Bible270.today - 4, @reader.effective_start_date
    end

    def test_the_final_turbo_checkoff_shows_completion_and_the_next_day_action
      @reader.mark_day_complete!(1)
      @reader.checkoffs.find_by!(day: 1, track: 'pp', part: 0).destroy!
      sign_in_as(@reader)

      post "#{mount}/day/1/toggle/pp/0", headers: turbo_stream_headers

      assert_response :success
      assert @reader.reload_progress.day_complete?(1)
      assert_select 'turbo-stream[action="replace"][target="day_progress_1"]' do
        assert_select '.b270-badge', text: 'Complete'
        assert_select '.b270-day-complete[role="status"]', text: %r{Day 1 complete} do
          assert_select '> div'
        end
        assert_select "a[href='#{mount}/day/2']", text: %r{Continue to Day 2}
      end
      assert_select 'turbo-stream[action="replace"][target="completers_1"]', text: %r{Finished this day}
    end

    def test_unchecking_a_portion_removes_the_completion_panel
      @reader.mark_day_complete!(1)
      sign_in_as(@reader)

      post "#{mount}/day/1/toggle/pp/0", headers: turbo_stream_headers

      assert_select 'turbo-stream[action="replace"][target="day_progress_1"]' do
        assert_select '.b270-day-complete', count: 0
        assert_select '.b270-badge', text: 'Complete', count: 0
      end
      assert_select 'turbo-stream[action="replace"][target="completers_1"]' do
        assert_select '.b270-completers', count: 1
        assert_select '.b270-completers span', count: 0
      end
    end

    def test_completing_the_last_day_links_to_progress_not_a_nonexistent_day
      day = Bible270::Plan::DAYS
      @reader.mark_day_complete!(day)
      missing = @reader.checkoffs.where(day: day).first
      missing.destroy!
      sign_in_as(@reader)

      post "#{mount}/day/#{day}/toggle/#{missing.track}/#{missing.part}", headers: turbo_stream_headers

      assert_select "turbo-stream[target='day_progress_#{day}']" do
        assert_select '.b270-day-complete', text: %r{Day #{day} complete}
        assert_select "a[href='#{mount}/progress']", text: %r{View My Progress}
        assert_select "a[href='#{mount}/day/#{day + 1}']", count: 0
      end
    end

  private

    def completion_frame
      Bible270::ScriptureFrames::Entry.new(
        id: 'default:completion-example', reference: 'Example 1:2', translation: 'TEST',
        text: "First sample line.\nSecond sample line.", attribution: 'Sample <b>credit</b> & contributors.'
      )
    end

    def assert_completion_root(event_id, &)
      assert_select("div.b270-completion[data-b270-completion][data-b270-day='1']" \
                    "[data-b270-completion-event='#{event_id}'][data-turbo-temporary][hidden]", count: 1, &)
    end

    def assert_completion_frame(frame)
      assert_select '.b270-completion-frame[data-b270-completion-frame]', count: 1 do
        assert_select '[data-b270-scripture-art]:not([hidden])', count: 1 do
          %i[text reference translation attribution].each do |field|
            assert_select "[data-b270-scripture-#{field}]", count: 1 do |nodes|
              assert_equal frame.public_send(field), nodes.first.text
              assert_empty nodes.first.element_children, "#{field} must be rendered as plaintext"
            end
          end
        end
      end
    end

    def turbo_stream_headers
      { 'Accept' => 'text/vnd.turbo-stream.html' }
    end
  end
end
