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
      # ensure_started! only applies when readers keep their own start dates and
      # there is no community-wide one.
      skip 'a community start date is set' if Bible270.config.start_date
      skip 'readers do not set their own start date' unless Bible270.config.allow_reader_start_date

      sign_in_as(@reader)
      post "#{mount}/day/1/toggle/nt"

      refute_nil @reader.reload.started_on, 'the first check-off should start their clock'
    end
  end
end
