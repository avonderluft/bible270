# frozen_string_literal: true

require 'test_helper'

# sessions#create and #failure, through the real middleware. Everything else in
# this controller is covered by the email flow; these two only run when a provider
# hands back an auth hash, so they had never been executed.
if RAILS_LOADED
  class OmniAuthSessionsTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
    end

    def teardown
      Bible270::Setting.open_enrollment!
    end

    def mount = Bible270.config.mount_at.chomp('/')

    # The request phase redirects to the callback; following it runs sessions#create.
    def sign_in_through(provider)
      post "#{mount}/auth/#{provider}"
      follow_redirect!
    end

    def test_a_new_reader_is_created_from_the_provider
      with_omniauth do |provider|
        sign_in_through(provider)
      end

      assert_equal 1, Bible270::Reader.count
      reader = Bible270::Reader.last
      assert_equal 'developer', reader.provider
      assert_equal '12345', reader.uid
      assert_equal 'Andrew vonderLuft', reader.display_name
      assert_equal 'andrew@example.org', reader.email
    end

    def test_signing_in_again_reuses_the_reader
      2.times { with_omniauth { |provider| sign_in_through(provider) } }

      assert_equal 1, Bible270::Reader.count
    end

    def test_the_reader_is_welcomed_by_name
      with_omniauth { |provider| sign_in_through(provider) }

      assert_response :redirect
      assert_match(%r{Welcome Andrew}, flash[:notice].to_s)
    end

    def test_the_session_survives_the_redirect
      with_omniauth { |provider| sign_in_through(provider) }
      follow_redirect!

      get "#{mount}/profile"
      assert_response :success, 'should be signed in'
    end

    def test_signing_in_sets_the_remember_cookie
      with_omniauth { |provider| sign_in_through(provider) }

      assert cookies[:bible270_remember].present?
      refute_nil Bible270::Reader.last.remember_token
    end

    # Where the reader was before signing in, when it is somewhere safe.
    def test_the_reader_returns_to_where_they_started
      with_omniauth(origin: "#{Bible270.config.mount_at.chomp('/')}/day/7") do |provider|
        sign_in_through(provider)
      end

      assert_equal "#{mount}/day/7", URI.parse(response.location).path
    end

    def test_an_offsite_origin_is_ignored
      with_omniauth(origin: 'https://evil.test/phish') { |provider| sign_in_through(provider) }

      refute_match(%r{evil\.test}, response.location)
    end

    # ---- a closed run ------------------------------------------------------

    def test_a_closed_run_turns_away_someone_new
      Bible270::Setting.close_enrollment!

      with_omniauth { |provider| sign_in_through(provider) }

      assert_equal 0, Bible270::Reader.count
      assert_match(%r{closed}i, flash[:alert].to_s)
    end

    def test_a_closed_run_still_admits_an_existing_reader
      with_omniauth { |provider| sign_in_through(provider) }
      assert_equal 1, Bible270::Reader.count
      Bible270::Setting.close_enrollment!
      reset!

      with_omniauth { |provider| sign_in_through(provider) }

      assert_equal 1, Bible270::Reader.count
      assert_match(%r{Welcome}, flash[:notice].to_s)
    end

    # ---- when it goes wrong ------------------------------------------------

    # OmniAuth sends a declined sign-in to its failure endpoint, which the engine
    # routes to sessions#failure. Asserted on where it ends up rather than on the
    # flash, which does not survive the whole redirect chain reliably.
    def test_a_declined_sign_in_creates_nobody_and_returns_to_sign_in
      with_failed_omniauth do |provider|
        post "#{mount}/auth/#{provider}"
        follow_redirect! while response.redirect? && response.location.include?('/auth/')
      end

      assert_equal 0, Bible270::Reader.count
      assert_match(%r{/sign_in}, response.location.to_s)
    end

    # The message arrives underscored from OmniAuth.
    def test_the_reason_is_made_readable
      get "#{mount}/auth/failure", params: { message: 'invalid_credentials' }

      assert_match(%r{invalid credentials}, flash[:alert].to_s)
    end

    def test_a_failure_with_no_reason_still_reads
      get "#{mount}/auth/failure"

      assert_match(%r{unknown error}, flash[:alert].to_s)
    end

    # Reaching the callback without an auth hash — a stale tab, or someone poking
    # at the URL — must not raise.
    #
    # The provider here is one no strategy is configured for, so the middleware
    # passes the request through untouched and the action sees no auth. Using
    # :developer would not do: its own strategy answers that URL and supplies a
    # hash, which is what an earlier version of this test tripped over.
    def test_the_callback_without_an_auth_hash_is_handled
      get "#{mount}/auth/nosuchprovider/callback"

      assert_response :redirect
      assert_match(%r{didn't complete}, flash[:alert].to_s)
      assert_equal 0, Bible270::Reader.count
    end
  end
end
