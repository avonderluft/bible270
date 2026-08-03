# frozen_string_literal: true

if RAILS_LOADED
  # Phones discard a browser-session cookie within days, so readers were being
  # asked to sign in again constantly. A long-lived encrypted cookie restores the
  # session.
  class RememberMeTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
    end

    def mount = Bible270.config.mount_at.chomp('/')

    def sign_in(email = 'reader@example.org')
      _record, raw = Bible270::SignInToken.issue!(email, first_name: 'A', last_name: 'Reader')
      get "#{mount}/sign_in/email/#{raw}"
      Bible270::Reader.find_by(uid: email)
    end

    def test_signing_in_issues_a_remember_token
      reader = sign_in

      refute_nil reader
      refute_nil reader.reload.remember_token, 'a token should be stored for the cookie'
      assert cookies[:bible270_remember].present?, 'the cookie should be set'
    end

    def test_the_session_is_restored_after_the_browser_forgets_it
      sign_in
      remembered = cookies[:bible270_remember]

      # A new browser session: session cookie gone, remember cookie kept, exactly
      # as when a phone discards the former.
      reset!
      cookies[:bible270_remember] = remembered
      get "#{mount}/day/1"

      assert_response :success
      refute_match(%r{Sign in}i, response.body.split('</header>').first.to_s,
                   'the header should not offer sign-in to a remembered reader')
    end

    def test_signing_out_clears_the_cookie
      sign_in
      delete "#{mount}/sign_out"

      assert cookies[:bible270_remember].blank?, 'the long-lived cookie must go too'
    end

    def test_a_tampered_cookie_is_ignored
      sign_in
      reset!
      cookies[:bible270_remember] = 'not-a-valid-encrypted-value'
      get "#{mount}/day/1"

      assert_response :success
      assert_equal 1, Bible270::Reader.count, 'no reader should be created or matched'
    end

    def test_forgetting_a_reader_invalidates_every_device
      reader = sign_in
      remembered = cookies[:bible270_remember]
      reader.forget!

      reset!
      cookies[:bible270_remember] = remembered
      get "#{mount}/day/1"

      assert_response :success
      assert_nil reader.reload.remember_token
    end

    def test_it_can_be_switched_off
      previous = Bible270.config.remember_for
      Bible270.config.remember_for = nil

      sign_in
      assert cookies[:bible270_remember].blank?, 'no cookie when remember_for is nil'
    ensure
      Bible270.config.remember_for = previous
    end
  end
end
