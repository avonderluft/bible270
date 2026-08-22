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
      assert_select '.b270-brand' do
        assert_select '.b270-title', text: Bible270.config.app_name
        assert_select '.b270-tagline', count: 0
      end
      assert_select 'p.b270-eyebrow', text: Bible270.config.tagline
      assert_select 'details.b270-index summary', text: 'View all 270 days'
    end

    def test_navigation_uses_clear_labels_and_a_mobile_menu
      get "#{mount}/"

      assert_select 'nav.b270-nav[aria-label="Primary navigation"]' do
        assert_select 'div.b270-desktopnav' do
          assert_select 'a', text: 'Community'
          assert_select 'a', text: 'Reflections'
        end
        assert_select 'div.b270-navmenu' do
          assert_select 'button.b270-navtoggle[type="button"][aria-label="Menu"]' \
                        '[aria-expanded="false"][aria-controls="b270-mobile-navigation"]' do
            assert_select 'span.b270-menuicon[aria-hidden="true"] > span', count: 3
          end
          assert_select 'div#b270-mobile-navigation.b270-navlinks[hidden]'
        end
      end
      assert(css_select('script[nonce]').any? { |script| script.text.include?('Bible270NavigationMenu') })
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
      refute_match(%r{No one has finished this day yet}, response.body)
      refute_match(%r{No reflections yet}, response.body)
    end

    def test_a_day_page_gives_visitors_one_sign_in_invitation
      get "#{mount}/day/1"

      prompt = 'Sign in to track your reading and join the conversation.'
      assert_select 'p.b270-signin-hint', count: 1, text: prompt
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
