# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class ReadersControllerTest < ActionDispatch::IntegrationTest
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

    def test_the_community_page_lists_readers
      get "#{mount}/community"

      assert_response :success
      assert_select 'p.b270-eyebrow', text: 'Community'
      assert_select 'h1', text: 'Reading together'
      assert_match(%r{R Reader}, response.body)
      assert_match(%r{Other Reader}, response.body)
    end

    def test_the_community_is_alphabetical_instead_of_ranked_by_progress
      @reader.mark_through!(5)
      get "#{mount}/community"

      assert_response :success
      assert_operator response.body.index('Other Reader'), :<, response.body.index('R Reader'),
                      'progress should not determine community standing'
      assert_select '.b270-li .rank', count: 0
      assert_select '.b270-li .stat', count: 0
    end

    def test_the_overview_links_to_fellow_readers_without_previewing_them
      get "#{mount}/"

      assert_response :success
      assert_select 'h2.b270-section-h', text: 'Reading together', count: 0
      assert_select "a[href='#{mount}/community']", text: 'Meet your fellow readers →'
      refute_match(%r{R Reader|Other Reader}, response.body)
    end

    def test_the_overview_omits_start_date_status_and_controls
      @reader.set_start_date!(Bible270.today - 9)
      sign_in_as(@reader)

      get "#{mount}/"

      assert_response :success
      assert_select '.b270-startdate', count: 0
      refute_match(%r{reading at your own pace|Change start date|Set a start date}, response.body)
    end

    def test_the_progress_page_retains_start_date_status_and_controls
      skip 'readers may not set their own schedule' unless Bible270.config.allow_reader_start_date

      @reader.set_start_date!(Bible270.today - 9)
      sign_in_as(@reader)

      get "#{mount}/progress"

      assert_response :success
      assert_select '.b270-startdate', text: %r{reading at your own pace}
      assert_select 'details.b270-startedit summary', text: 'Change start date'
    end

    # ---- the progress page -------------------------------------------------

    def test_the_progress_page_invites_a_visitor_to_sign_in
      get "#{mount}/progress"

      assert_response :success
      assert_match(%r{Sign in}i, response.body)
      refute_match(%r{days complete}, response.body)
      assert_select '.b270-next-steps', count: 0
    end

    def test_the_progress_page_shows_a_readers_standing
      @reader.mark_through!(4)
      sign_in_as(@reader)

      get "#{mount}/progress"

      assert_response :success
      assert_select 'p.b270-eyebrow', text: 'My Progress'
      assert_select 'h1', text: 'Your reading journey'
      assert_match(%r{4}, response.body)
      assert_match(%r{days complete}, response.body)
    end

    def test_the_progress_page_links_partially_read_days_to_remaining_portions
      @reader.checkoffs.create!(day: 1, track: 'ot', part: 0)
      @reader.reload_progress
      sign_in_as(@reader)

      get "#{mount}/progress"

      assert_select '.b270-next-steps' do
        assert_select '#finish-started-heading', text: 'Finish what you started'
        assert_select 'a[href$="/day/1#reading_1_ot"]', text: 'Genesis 2'
        assert_select 'a[href$="/day/1#reading_1_ot"]', text: 'Genesis 3'
        assert_select 'a[href$="/day/1#reading_1_nt"]', text: 'Matthew 1'
        assert_select 'a[href$="/day/1#reading_1_pp"]', text: 'Psalm 1'
        assert_select 'a.b270-task-link', text: %r{Continue}
      end
    end

    def test_the_progress_page_summarizes_the_week_and_next_milestone
      week_start = Bible270.today - ((Bible270.today.wday + 6) % 7)
      @reader.set_start_date!(week_start)
      @reader.mark_day_complete!(1)
      sign_in_as(@reader)

      get "#{mount}/progress"

      scheduled = (Bible270.today - week_start).to_i + 1
      assert_select '.b270-week-count', text: %r{1 of #{scheduled}.*complete so far this week}
      assert_select "progress.b270-week-progress[value='1'][max='#{scheduled}']"
      assert_select '.b270-milestone', text: %r{30 days.*30-day milestone}
      assert_select '.b270-next-note', text: %r{29 days to go}
    end

    def test_the_progress_page_offers_the_next_day
      @reader.mark_through!(2)
      sign_in_as(@reader)

      get "#{mount}/progress"

      # Day 3 is next, so it should say Continue rather than Start.
      assert_match(%r{Continue reading}, response.body)
      assert_match(%r{/day/3}, response.body)
    end

    def test_a_reader_behind_schedule_gets_clear_recovery_choices
      @reader.set_start_date!(Bible270.today - 9)
      sign_in_as(@reader)

      get "#{mount}/progress"

      assert_select '.b270-recovery' do
        assert_select 'a.b270-btn[href$="/day/1"]', text: %r{Catch up from Day 1}
        assert_select 'a.b270-todaylink[href$="/day/10"]', text: %r{Read with the community}
        assert_select 'form', count: 0
      end
      assert_match(%r{completed readings stay saved}, response.body)
    end

    def test_recovery_choices_are_hidden_when_the_next_reading_is_today
      @reader.set_start_date!(Bible270.today)
      sign_in_as(@reader)

      get "#{mount}/progress"

      assert_select '.b270-recovery', count: 0
      assert_match(%r{Start reading — Day 1}, response.body)
    end

    def test_the_progress_page_lists_recent_reflections
      @reader.comments.create!(day: 2, body: 'A note to myself')
      sign_in_as(@reader)

      get "#{mount}/progress"

      assert_match(%r{A note to myself}, response.body)
    end

    def test_the_progress_page_does_not_repeat_the_day_index
      sign_in_as(@reader)
      get "#{mount}/progress"

      # It draws its own grid, so the layout's copy must be suppressed. Count the
      # markup only — the inlined stylesheet also mentions .b270-grid, which made
      # an earlier version of this test read two where one was correct.
      assert_equal 1, response.body.scan('class="b270-grid"').size
    end

    def test_a_reader_page_renders
      get "#{mount}/readers/#{@reader.id}"

      assert_response :success
      assert_match(%r{R Reader}, response.body)
    end

    def test_an_unknown_reader_redirects_rather_than_erroring
      get "#{mount}/readers/999999"

      assert_response :redirect
    end

    def test_a_reader_page_shows_their_recent_reflections
      @reader.comments.create!(day: 1, body: 'A reflection of mine')
      get "#{mount}/readers/#{@reader.id}"

      assert_match(%r{A reflection of mine}, response.body)
    end

    def test_a_hidden_reflection_is_not_shown_on_their_page
      @reader.comments.create!(day: 1, body: 'Visible here')
      hidden = @reader.comments.create!(day: 2, body: 'Hidden here')
      hidden.hide!

      get "#{mount}/readers/#{@reader.id}"

      assert_match(%r{Visible here}, response.body)
      refute_match(%r{Hidden here}, response.body)
    end

    def test_reflections_come_before_the_day_grid_on_a_reader_page
      @reader.comments.create!(day: 1, body: 'An early thought')
      get "#{mount}/readers/#{@reader.id}"

      assert_response :success
      assert_operator response.body.index('An early thought'), :<,
                      response.body.index('class="b270-grid"'),
                      'reflections should read before the 270-day grid'
    end

    def test_a_reader_page_offers_no_moderation_controls
      @reader.comments.create!(day: 1, body: 'Not yours to hide')
      get "#{mount}/readers/#{@reader.id}"

      refute_match(%r{Hide</button>|>Hide<}, response.body,
                   'hide and restore belong to the admin panel only')
    end

    def test_a_reader_with_no_reflections_says_so
      get "#{mount}/readers/#{@reader.id}"

      assert_match(%r{No reflections yet}, response.body)
    end

    # ---- start dates -------------------------------------------------------

    def test_a_reader_can_set_their_start_date
      skip 'readers may not set their own' unless Bible270.config.allow_reader_start_date
      sign_in_as(@reader)

      patch "#{mount}/start-date", params: { start_date: '2026-09-06' }

      assert_equal Date.new(2026, 9, 6), @reader.reload.started_on
    end

    def test_an_unreadable_date_is_refused
      skip 'readers may not set their own' unless Bible270.config.allow_reader_start_date
      sign_in_as(@reader)

      patch "#{mount}/start-date", params: { start_date: 'the feast of stephen' }

      assert_nil @reader.reload.started_on
    end

    def test_a_reader_can_clear_their_start_date
      skip 'readers may not set their own' unless Bible270.config.allow_reader_start_date
      sign_in_as(@reader)
      patch "#{mount}/start-date", params: { start_date: '2026-09-06' }

      delete "#{mount}/start-date"

      assert_nil @reader.reload.started_on
    end

    def test_a_visitor_cannot_set_a_start_date
      patch "#{mount}/start-date", params: { start_date: '2026-09-06' }

      assert_nil @reader.reload.started_on
    end

    def test_start_date_editor_is_hidden_when_reader_dates_are_disabled
      previous = Bible270.config.allow_reader_start_date
      @reader.set_start_date!(Date.new(2026, 9, 6))
      Bible270.config.allow_reader_start_date = false
      sign_in_as(@reader)

      ["#{mount}/", "#{mount}/progress"].each do |path|
        get path

        assert_response :success
        assert_select 'details.b270-startedit', count: 0
        assert_select "form[action='#{mount}/start-date']", count: 0
        refute_match(%r{Change start date|Set a start date}, response.body)
        assert_select '.b270-next-note', text: 'This plan is not tied to calendar dates.' if path.end_with?('/progress')
      end
    ensure
      Bible270.config.allow_reader_start_date = previous
    end

    def test_readers_are_turned_away_when_the_community_date_rules
      previous = Bible270.config.allow_reader_start_date
      Bible270.config.allow_reader_start_date = false
      sign_in_as(@reader)

      patch "#{mount}/start-date", params: { start_date: '2026-09-06' }

      assert_nil @reader.reload.started_on
    ensure
      Bible270.config.allow_reader_start_date = previous
    end
  end
end
