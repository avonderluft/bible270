# frozen_string_literal: true

require 'test_helper'

# Renders real pages through the engine. Every render-time bug this gem has had
# — an unqualified constant in a template, a helper Rails never mixed in, a
# missing mailer template — was invisible to static checks and would have failed
# here immediately.
# The whole class is guarded: ActionDispatch::IntegrationTest only exists once
# Rails has loaded, and the pure suite must still run where it hasn't.
if RAILS_LOADED
  class EngineIntegrationTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
    end

    def mount = Bible270.config.mount_at.chomp('/')

    def test_the_overview_renders
      get "#{mount}/"

      assert_response :success
      assert_match(%r{270}, response.body)
    end

    def test_a_day_page_renders_all_three_readings
      get "#{mount}/day/1"

      assert_response :success
      assert_match(%r{Genesis 1}, response.body)
      assert_match(%r{Matthew 1}, response.body)
      assert_match(%r{Psalm 1}, response.body)
    end

    # Day 1's Old Testament reading is three chapters, so with per-chapter
    # check-offs it should list each rather than only the range.
    def test_a_multi_chapter_reading_offers_a_box_per_chapter
      needs_chapter_parts!
      get "#{mount}/day/1"

      assert_response :success
      assert_match(%r{Genesis 2}, response.body)
      assert_match(%r{Genesis 3}, response.body)
    end

    def test_the_sign_in_page_renders
      get "#{mount}/sign_in"

      assert_response :success
    end

    def test_the_community_page_renders
      get "#{mount}/community"

      assert_response :success
    end

    def test_an_out_of_range_day_is_not_found
      get "#{mount}/day/999"

      assert_includes [302, 404], response.status
    end

    def test_the_admin_panel_is_invisible_without_configuration
      get "#{mount}/admin"

      refute_equal 200, response.status, 'admin must not be reachable unless configured'
    end
  end
end
