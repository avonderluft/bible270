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

    def sign_in_as(reader)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"
    end

    # created_at is set explicitly: several reflections made in the same test would
    # otherwise share a timestamp and order unpredictably.
    def reflection(reader, day, body, at)
      reader.comments.create!(day: day, body: body, created_at: at, updated_at: at)
    end

    # The page no longer keeps its own filtered grid; it offers the same collapsed
    # "View all 270 days" control the layout gives every other page.
    def test_it_shows_the_standard_collapsed_day_index
      reflection(@mary, 3, 'On day three', 1.hour.ago)

      get "#{mount}/reflections"

      assert_select 'details.b270-index' do
        assert_select 'summary', text: 'View all 270 days'
        assert_select '.b270-grid', count: 1
      end
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

    # ---- the empty state ---------------------------------------------------

    def test_hidden_reflections_do_not_show_a_conversation
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
      assert_select '.b270-pagination a', text: 'Older →'
    end

    def test_older_reflections_are_available_without_duplicates
      Bible270.config.reflections_page_size = 2
      4.times { |n| reflection(@mary, n + 1, "Paged reflection #{n}", (10 - n).hours.ago) }

      get "#{mount}/reflections"

      assert_match(%r{Paged reflection 3}, response.body)
      assert_match(%r{Paged reflection 2}, response.body)
      refute_match(%r{Paged reflection 1}, response.body)

      get "#{mount}/reflections", params: { page: 2 }

      assert_match(%r{Paged reflection 1}, response.body)
      assert_match(%r{Paged reflection 0}, response.body)
      refute_match(%r{Paged reflection 3}, response.body)
      assert_select '.b270-pagination a', text: '← Newer'
    end

    def test_reflections_can_be_filtered_by_day_and_author
      reflection(@mary, 3, 'Mary on three', 3.hours.ago)
      reflection(@mary, 4, 'Mary on four', 2.hours.ago)
      reflection(@andrew, 3, 'Andrew on three', 1.hour.ago)

      get "#{mount}/reflections", params: { day: 3, reader_id: @mary.id }

      assert_match(%r{Mary on three}, response.body)
      refute_match(%r{Mary on four}, response.body)
      refute_match(%r{Andrew on three}, response.body)
      assert_select "option[value='3'][selected='selected']"
      assert_select "option[value='#{@mary.id}'][selected='selected']"
    end

    def test_filters_have_a_clear_empty_state
      reflection(@mary, 3, 'Only Mary', 1.hour.ago)
      reflection(@andrew, 4, 'Only Andrew', 30.minutes.ago)

      get "#{mount}/reflections", params: { day: 3, reader_id: @andrew.id }

      assert_select '.b270-filter-empty', text: %r{No reflections match these filters}
      assert_select '.b270-filter-empty a', text: 'Show all reflections'
    end

    # ---- new activity -------------------------------------------------------

    def test_a_first_visit_establishes_a_baseline_without_marking_old_threads_new
      reflection(@andrew, 1, 'Already here', 1.hour.ago)
      sign_in_as(@mary)

      get "#{mount}/reflections"

      assert_select '.b270-new-reflection', count: 0
      assert @mary.reload.reflections_seen_at
    end

    def test_reflections_stay_available_while_the_seen_migration_is_pending
      reflection(@andrew, 1, 'Still readable', 1.hour.ago)
      sign_in_as(@mary)

      Bible270::Reader.stub(:reflections_seen_column?, false) do
        get "#{mount}/reflections"
      end

      assert_response :success
      assert_match(%r{Still readable}, response.body)
      assert_select '.b270-new-reflection', count: 0
    end

    def test_new_roots_and_new_replies_are_marked_since_the_previous_visit
      @mary.update_column(:reflections_seen_at, 2.days.ago)
      old = reflection(@andrew, 1, 'Old and quiet', 3.days.ago)
      active = reflection(@andrew, 2, 'Old but active', 3.days.ago)
      fresh = reflection(@andrew, 3, 'Brand new', 1.hour.ago)
      @mary.comments.create!(day: 2, body: 'A new reply', parent: active, created_at: 30.minutes.ago)
      sign_in_as(@mary)

      get "#{mount}/reflections"

      assert_select "#thread-#{old.id} .b270-new-reflection", count: 0
      assert_select "#thread-#{active.id} .b270-new-reflection", text: 'New since your last visit'
      assert_select "#thread-#{fresh.id} .b270-new-reflection", text: 'New since your last visit'
      assert_operator @mary.reload.reflections_seen_at, :>, 2.days.ago
    end

    def test_older_pages_keep_the_original_new_activity_cutoff
      Bible270.config.reflections_page_size = 1
      @mary.update_column(:reflections_seen_at, 3.days.ago)
      reflection(@andrew, 1, 'First new thread', 2.hours.ago)
      reflection(@andrew, 2, 'Second new thread', 1.hour.ago)
      sign_in_as(@mary)

      get "#{mount}/reflections"

      older_link = css_select('.b270-pagination a').find { |link| link.text.include?('Older') }
      assert_includes older_link['href'], 'since='
      get older_link['href']

      assert_select '.b270-new-reflection', text: 'New since your last visit'
      assert_match(%r{First new thread}, response.body)
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
