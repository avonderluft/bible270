# frozen_string_literal: true

require 'test_helper'

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
      assert_match(%r{width:min\(75vw,97\.5vh\)}, response.body)
      assert_match(%r{animationend}, response.body)
    end

    def test_only_the_checkoff_that_completes_a_day_marks_the_completion_effect
      sign_in_as(@reader)
      @reader.mark_day_complete!(1)
      @reader.checkoffs.find_by!(day: 1, track: 'nt', part: 0).destroy!

      post "#{mount}/day/1/toggle/nt/0",
           params: { checked: '1' },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      assert_response :success
      assert_select '[data-b270-day-just-completed="true"][data-b270-day="1"]', count: 1
      assert_select 'svg[data-b270-completion-dove][aria-hidden="true"][data-b270-day="1"]', count: 1 do
        assert_select '.b270-dove-feathers', count: 0
      end

      post "#{mount}/day/1/toggle/nt/0",
           params: { checked: '1' },
           headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

      assert_response :success
      assert_select '[data-b270-day-just-completed]', count: 0
      assert_select '[data-b270-completion-dove]', count: 0
    end

    def test_a_final_html_checkoff_redirects_to_the_dove_without_a_success_message
      sign_in_as(@reader)
      @reader.mark_day_complete!(1)
      @reader.checkoffs.find_by!(day: 1, track: 'nt', part: 0).destroy!

      post "#{mount}/day/1/toggle/nt/0", params: { checked: '1' }

      assert_response :redirect
      assert_nil flash[:b270_interaction_status]
      assert_equal 1, flash[:b270_day_just_completed]

      follow_redirect!

      assert_response :success
      assert_select '#day_progress_1 svg[data-b270-completion-dove][data-b270-day="1"]', count: 1
      assert_select '#b270-interaction-status', text: '', count: 1
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

    def turbo_stream_headers
      { 'Accept' => 'text/vnd.turbo-stream.html' }
    end
  end
end
