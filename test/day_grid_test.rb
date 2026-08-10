# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class DayGridTest < ActionDispatch::IntegrationTest
    # The stylesheet is inlined into every response, so assertions must match the
    # class attribute rather than a bare class name.
    TALK_CELL = %r{class="[^"]*\btalk\b[^"]*"}

    def setup
      needs_rails!
      clear_engine_tables!
      @reader = Bible270::Reader.create!(provider: 'email', uid: 'r@example.org', email: 'r@example.org',
                                         display_name: 'R Reader', first_name: 'R', last_name: 'Reader')
    end

    def mount = Bible270.config.mount_at.chomp('/')

    def sign_in_as(reader)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"
    end

    # ---- the tooltip -------------------------------------------------------

    def test_each_square_carries_its_readings
      get "#{mount}/day/1"

      assert_response :success
      assert_match(%r{title="Genesis 1–3 · Matthew 1 · Psalm 1"}, response.body)
    end

    def test_the_last_day_too
      get "#{mount}/day/1"

      assert_match(%r{title="Zechariah 14, Malachi 1–4 · Revelation 22 · Proverbs 31:10–31"},
                   response.body)
    end

    def test_every_square_has_a_title
      get "#{mount}/day/1"

      cells = response.body.scan(%r{class="b270-cell[^"]*"[^>]*title="[^"]+"}).size
      assert_equal Bible270::Plan::DAYS, cells, 'all 270 squares should say what is on that day'
    end

    def test_original_language_labels_name_each_passages_language
      @reader.update_bible_version('HEB/GRK')
      sign_in_as(@reader)
      get "#{mount}/day/1"

      assert_equal 2, response.body.scan('(Hebrew)').size
      assert_equal 1, response.body.scan('(Greek)').size
      refute_includes response.body, '(HEB/GRK)'
    end

    # ---- reflections -------------------------------------------------------

    def test_a_day_with_no_reflections_is_not_marked
      get "#{mount}/day/1"

      refute_match(TALK_CELL, response.body)
    end

    def test_a_day_with_a_reflection_is_marked
      @reader.comments.create!(day: 5, body: 'A thought')
      get "#{mount}/day/1"

      assert_response :success
      assert_match(TALK_CELL, response.body)
      assert_equal 1, response.body.scan(TALK_CELL).size, 'one day has reflections'
    end

    # Hidden reflections are invisible to readers, so the square must not advertise
    # a conversation they cannot see.
    def test_a_hidden_reflection_does_not_mark_the_day
      comment = @reader.comments.create!(day: 5, body: 'Questionable')
      comment.hide!

      get "#{mount}/day/1"

      refute_match(TALK_CELL, response.body)
    end

    def test_a_reply_marks_its_day_too
      thought = @reader.comments.create!(day: 5, body: 'A thought')
      other = Bible270::Reader.create!(provider: 'email', uid: 'o@example.org', email: 'o@example.org',
                                       display_name: 'Other Reader', first_name: 'Other', last_name: 'Reader')
      other.comments.create!(day: 5, body: 'An answer', parent: thought)

      get "#{mount}/day/1"

      assert_equal 1, response.body.scan(TALK_CELL).size, 'still one day, not two'
    end

    def test_several_days_are_each_marked
      [3, 9, 200].each { |day| @reader.comments.create!(day: day, body: "Day #{day}") }
      get "#{mount}/day/1"

      assert_equal 3, response.body.scan(TALK_CELL).size
    end

    # ---- progress, unchanged ----------------------------------------------

    def test_completion_still_shows_alongside_reflections
      @reader.mark_day_complete!(5)
      @reader.comments.create!(day: 5, body: 'A thought')
      sign_in_as(@reader)

      get "#{mount}/day/1"

      # Both facts on one square: the fill says finished, the border says talked.
      assert_match(%r{class="b270-cell complete talk"}, response.body)
    end

    def test_a_partly_read_day_with_reflections
      @reader.checkoffs.create!(day: 5, track: 'nt')
      @reader.comments.create!(day: 5, body: 'A thought')
      sign_in_as(@reader)

      get "#{mount}/day/1"

      assert_match(%r{class="b270-cell partial talk"}, response.body)
    end

    # ---- the note ----------------------------------------------------------

    def test_the_grid_says_what_the_dot_means
      get "#{mount}/day/1"

      assert_match(%r{Dot indicates days with reflections}, response.body)
    end

    # ---- the query ---------------------------------------------------------

    # 270 squares must not mean 270 queries.
    def test_the_days_with_reflections_are_fetched_once
      [3, 9].each { |day| @reader.comments.create!(day: day, body: "Day #{day}") }

      queries = 0
      counter = ->(*, payload) { queries += 1 if payload[:sql]&.include?('bible270_comments') }
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        get "#{mount}/day/1"
      end

      assert_operator queries, :<=, 3, "#{queries} comment queries for one page is too many"
    end
  end
end
