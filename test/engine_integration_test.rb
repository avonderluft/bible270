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

    def test_navigation_uses_clear_labels_and_a_mobile_menu
      get "#{mount}/"

      assert_select 'nav.b270-nav[aria-label="Primary navigation"]' do
        assert_select 'div.b270-desktopnav' do
          assert_select 'a', text: 'Community'
          assert_select 'a', text: 'Reflections'
        end
        assert_select 'details.b270-navmenu' do
          assert_select 'summary.b270-navtoggle[aria-label="Menu"]' do
            assert_select 'span.b270-menuicon[aria-hidden="true"] > span', count: 3
          end
        end
      end
    end

    def test_signed_in_navigation_labels_personal_progress_clearly
      reader = Bible270::Reader.create!(provider: 'email', uid: 'r@example.org', email: 'r@example.org',
                                        display_name: 'R Reader', first_name: 'R', last_name: 'Reader')
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"

      get "#{mount}/"

      assert_select 'nav.b270-nav a', text: 'My Progress'
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

    def test_day_page_offers_an_accessible_compact_reading_mode
      reader = Bible270::Reader.create!(provider: 'email', uid: 'compact@example.org',
                                        email: 'compact@example.org', display_name: 'Compact Reader')
      reader.mark_day_complete!(1)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"

      get "#{mount}/day/1"

      assert_response :success
      assert_select '[data-b270-day-page][data-b270-reading-mode="full"]' do
        assert_select '[data-b270-reading-options][hidden]' do
          assert_select 'button[type="button"][data-b270-compact-toggle][aria-pressed="false"]',
                        text: 'Compact reading'
        end
        assert_select '.b270-day-community[data-b270-compact-hide]'
        assert_select '.b270-dayhead .b270-badge[data-b270-compact-hide]', text: 'Complete'
        assert_select '.b270-day-complete > div[data-b270-compact-hide]'
        assert_select ".b270-day-complete > a[href='#{mount}/day/2']", text: %r{Continue to Day 2}
        assert_select '.b270-daynav a[aria-label="Next day"]'
        assert_select '.b270-ref a[target="_blank"][rel="noopener"]', minimum: 3
        assert_select 'button.b270-toggle[aria-label]', minimum: 3
      end
      assert(css_select('script[nonce]').any? { |script| script.text.include?('Bible270ReadingMode') })
    end

    def test_day_navigation_uses_disabled_buttons_at_plan_boundaries
      get "#{mount}/day/1"

      assert_select 'button.b270-arrow.disabled[disabled][aria-label="Previous day unavailable"]', text: '‹'
      assert_select 'a.b270-arrow[aria-label="Next day"]'
      assert_select 'a.b270-arrow[href="#"]', count: 0

      get "#{mount}/day/#{Bible270::Plan::DAYS}"

      assert_select 'a.b270-arrow[aria-label="Previous day"]'
      assert_select 'button.b270-arrow.disabled[disabled][aria-label="Next day unavailable"]', text: '›'
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
