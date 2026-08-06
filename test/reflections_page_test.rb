# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class ReflectionsPageTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_size = Bible270.config.reflections_page_size
      @andrew = Bible270::Reader.create!(provider: 'email', uid: 'a@example.org', email: 'a@example.org',
                                         display_name: 'Andrew vonderLuft',
                                         first_name: 'Andrew', last_name: 'vonderLuft')
      @mary = Bible270::Reader.create!(provider: 'email', uid: 'm@example.org', email: 'm@example.org',
                                       display_name: 'Mary Smith', first_name: 'Mary', last_name: 'Smith')
    end

    def teardown
      Bible270.config.reflections_page_size = @previous_size
    end

    def mount = Bible270.config.mount_at.chomp('/')

    # created_at is set explicitly: several reflections made in the same test would
    # otherwise share a timestamp and order unpredictably.
    def reflection(reader, day, body, at)
      reader.comments.create!(day: day, body: body, created_at: at, updated_at: at)
    end

    # Every square on this page has a dot, so saying what the dot means would
    # explain nothing. The day pages, where most squares have none, still say it.
    def test_the_grid_note_is_omitted_here
      reflection(@mary, 3, 'On day three', 1.hour.ago)

      get "#{mount}/reflections"

      refute_match(%r{Dot indicates}, response.body)
    end

    def test_the_day_page_still_says_it
      reflection(@mary, 3, 'On day three', 1.hour.ago)

      get "#{mount}/day/1"

      assert_match(%r{Dot indicates}, response.body)
    end

    def test_the_nav_offers_it
      get "#{mount}/"

      assert_match(%r{href="[^"]*/reflections"}, response.body)
    end

    def test_an_empty_plan_says_so
      get "#{mount}/reflections"

      assert_response :success
      assert_match(%r{No one has written a reflection yet}, response.body)
    end

    # ---- the grid ----------------------------------------------------------

    def test_the_grid_shows_only_days_that_have_reflections
      reflection(@mary, 3, 'On day three', 3.days.ago)
      reflection(@andrew, 9, 'On day nine', 2.days.ago)

      get "#{mount}/reflections"

      assert_response :success
      cells = response.body.scan(%r{class="b270-cell[^"]*"}).size
      assert_equal 2, cells, 'two days have reflections, so two squares'
      assert_match(%r{/day/3"}, response.body)
      assert_match(%r{/day/9"}, response.body)
    end

    def test_the_grid_squares_still_carry_their_readings
      reflection(@mary, 1, 'On day one', 1.day.ago)

      get "#{mount}/reflections"

      assert_match(%r{title="Genesis 1–3 · Matthew 1 · Psalm 1"}, response.body)
    end

    def test_a_day_is_counted_once_however_many_reflections
      reflection(@mary, 3, 'One', 3.days.ago)
      reflection(@andrew, 3, 'Two', 2.days.ago)

      get "#{mount}/reflections"

      assert_equal 1, response.body.scan(%r{class="b270-cell[^"]*"}).size
    end

    def test_hidden_reflections_do_not_put_a_day_on_the_grid
      reflection(@mary, 3, 'Hidden one', 3.days.ago).hide!

      get "#{mount}/reflections"

      assert_match(%r{No one has written a reflection yet}, response.body)
    end

    # ---- the list ----------------------------------------------------------

    def test_the_newest_reflection_comes_first
      reflection(@mary, 1, 'The older one', 3.days.ago)
      reflection(@andrew, 2, 'The newer one', 1.hour.ago)

      get "#{mount}/reflections"

      assert_operator response.body.index('The newer one'), :<, response.body.index('The older one')
    end

    def test_each_thread_says_which_day_it_belongs_to
      reflection(@mary, 42, 'On day forty-two', 1.hour.ago)

      get "#{mount}/reflections"

      assert_match(%r{Day 42}, response.body)
    end

    def test_the_list_is_capped
      Bible270.config.reflections_page_size = 3
      6.times { |n| reflection(@mary, n + 1, "Reflection #{n}", (10 - n).hours.ago) }

      get "#{mount}/reflections"

      shown = (0..5).count { |n| response.body.include?("Reflection #{n}") }
      assert_equal 3, shown
    end

    # ---- the scripture links ------------------------------------------------

    def test_the_references_link_to_the_passage
      reflection(@mary, 1, 'On day one', 1.hour.ago)

      get "#{mount}/reflections"

      assert_response :success
      assert_match(%r{href="https://www\.biblegateway\.com/passage/\?search=Genesis\+1[^"]*"}, response.body)
      assert_match(%r{class="b270-reflink"}, response.body)
    end

    def test_all_three_tracks_are_linked
      reflection(@mary, 1, 'On day one', 1.hour.ago)

      get "#{mount}/reflections"

      %w[Genesis Matthew Psalm].each do |book|
        assert_match(%r{search=#{book}}, response.body, "#{book} should be a link")
      end
    end

    def test_a_visitor_gets_the_site_default_translation
      reflection(@mary, 1, 'On day one', 1.hour.ago)

      get "#{mount}/reflections"

      assert_match(%r{version=#{Bible270.config.bible_version}}, response.body)
    end

    def test_a_reader_gets_their_own_translation
      @mary.update_bible_version('KJV')
      reflection(@mary, 1, 'On day one', 1.hour.ago)
      _record, raw = Bible270::SignInToken.issue!(@mary.email)
      get "#{mount}/sign_in/email/#{raw}"

      get "#{mount}/reflections"

      assert_match(%r{version=KJV}, response.body)
    end

    # NASB95 is NASB1995 to Bible Gateway; sending the display code lands on a
    # search page instead of the passage.
    def test_the_gateway_code_is_used_not_the_display_code
      @mary.update_bible_version('NASB95')
      reflection(@mary, 1, 'On day one', 1.hour.ago)
      _record, raw = Bible270::SignInToken.issue!(@mary.email)
      get "#{mount}/sign_in/email/#{raw}"

      get "#{mount}/reflections"

      assert_match(%r{version=NASB1995}, response.body)
      refute_match(%r{version=NASB95&|version=NASB95"}, response.body)
    end

    def test_the_references_open_in_a_new_tab_safely
      reflection(@mary, 1, 'On day one', 1.hour.ago)

      get "#{mount}/reflections"

      assert_match(%r{rel="noopener"}, response.body)
    end

    # ---- threading ---------------------------------------------------------

    def test_replies_appear_under_their_reflection
      thought = reflection(@mary, 5, 'A thought', 2.days.ago)
      @andrew.comments.create!(day: 5, body: 'An answer', parent: thought, created_at: 1.hour.ago)

      get "#{mount}/reflections"

      assert_match(%r{class="b270-comment b270-reply"}, response.body)
      assert_operator response.body.index('A thought'), :<, response.body.index('An answer')
    end

    def test_a_reply_does_not_appear_as_a_thread_of_its_own
      thought = reflection(@mary, 5, 'A thought', 2.days.ago)
      @andrew.comments.create!(day: 5, body: 'An answer', parent: thought, created_at: 1.hour.ago)

      get "#{mount}/reflections"

      assert_equal 1, response.body.scan('class="b270-threadday"').size
    end

    # A conversation that is still going should not sink below quieter, newer
    # reflections.
    def test_a_reply_brings_its_thread_back_to_the_top
      old_thought = reflection(@mary, 5, 'The old thought', 10.days.ago)
      reflection(@andrew, 6, 'Something newer', 2.days.ago)
      @andrew.comments.create!(day: 5, body: 'A fresh answer', parent: old_thought, created_at: 1.hour.ago)

      get "#{mount}/reflections"

      assert_operator response.body.index('The old thought'), :<,
                      response.body.index('Something newer'),
                      'the thread with the newest reply should lead'
    end

    def test_a_hidden_reply_is_not_shown
      thought = reflection(@mary, 5, 'A thought', 2.days.ago)
      hidden = @andrew.comments.create!(day: 5, body: 'Questionable', parent: thought, created_at: 1.hour.ago)
      hidden.hide!

      get "#{mount}/reflections"

      refute_match(%r{Questionable}, response.body)
      assert_match(%r{A thought}, response.body)
    end

    def test_a_visitor_can_read_but_not_reply
      reflection(@mary, 5, 'A thought', 1.hour.ago)

      get "#{mount}/reflections"

      assert_match(%r{A thought}, response.body)
      refute_match(%r{reply_to=}, response.body)
    end
  end
end
