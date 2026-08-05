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

if RAILS_LOADED
  # The parts of sign-in not covered by the round-trip tests: where a reader is
  # sent afterwards, the rate limit, and the prompt for a missing name.
  class SessionsEdgeCasesTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_from = Bible270.config.mailer_from
      Bible270.config.mailer_from = 'no-reply@example.org'
    end

    def teardown
      Bible270.config.mailer_from = @previous_from
    end

    def mount = Bible270.config.mount_at.chomp('/')

    def test_a_reader_is_returned_to_where_they_started
      _record, raw = Bible270::SignInToken.issue!('r@example.org', first_name: 'R', last_name: 'Reader')
      get "#{mount}/sign_in/email/#{raw}", params: { origin: "#{mount}/day/7" }

      assert_response :redirect
      assert_match(%r{/day/7}, response.location)
    end

    # An origin pointing off-site would turn sign-in into an open redirect. Note
    # the integration host is itself www.example.com, so assert on the path
    # rather than the host, or the fallback looks like a leak.
    def test_an_offsite_origin_is_ignored
      _record, raw = Bible270::SignInToken.issue!('r@example.org', first_name: 'R', last_name: 'Reader')
      get "#{mount}/sign_in/email/#{raw}", params: { origin: 'https://evil.test/phish' }

      assert_response :redirect
      refute_match(%r{evil\.test}, response.location)
      refute_match(%r{phish}, response.location)
      assert_equal "#{mount}/", URI.parse(response.location).path
    end

    # Returning someone to the sign-in page after they have just signed in reads
    # as though it failed.
    def test_an_origin_back_into_the_auth_routes_is_ignored
      %W[#{mount}/sign_in #{mount}/sign_out #{mount}/auth/github/callback].each do |origin|
        _record, raw = Bible270::SignInToken.issue!("r#{origin.hash.abs}@example.org",
                                                    first_name: 'R', last_name: 'Reader')
        get "#{mount}/sign_in/email/#{raw}", params: { origin: origin }

        assert_response :redirect
        assert_equal "#{mount}/", URI.parse(response.location).path,
                     "#{origin} should fall back to the plan, not bounce back to auth"
      end
    end

    def test_a_new_reader_without_a_name_is_asked_for_one
      skip 'names not required' unless Bible270.config.email_sign_in_require_name

      _record, raw = Bible270::SignInToken.issue!('nameless@example.org')
      get "#{mount}/sign_in/email/#{raw}"

      assert_response :redirect
      assert_match(%r{/profile}, response.location)
    end

    def test_a_returning_reader_with_a_name_is_not_pestered
      Bible270::Reader.create!(provider: 'email', uid: 'known@example.org', email: 'known@example.org',
                               display_name: 'Known Reader', first_name: 'Known', last_name: 'Reader')
      _record, raw = Bible270::SignInToken.issue!('known@example.org')
      get "#{mount}/sign_in/email/#{raw}"

      refute_match(%r{/profile}, response.location.to_s)
    end

    def test_asking_too_often_stops_issuing_links
      limit = Bible270.config.email_sign_in_max_per_window

      (limit + 2).times do
        post "#{mount}/sign_in/email", params: { email: 'eager@example.org' }
      end

      assert_operator Bible270::SignInToken.where(email: 'eager@example.org').count, :<=, limit
    end

    def test_signing_out_leaves_no_session
      _record, raw = Bible270::SignInToken.issue!('r@example.org', first_name: 'R', last_name: 'Reader')
      get "#{mount}/sign_in/email/#{raw}"

      delete "#{mount}/sign_out"
      get "#{mount}/profile"

      assert_response :redirect
      assert_match(%r{sign_in}, response.location, 'should be signed out')
    end
  end
end

if RAILS_LOADED
  # Configuration-driven paths through sign-in that the round-trip tests miss.
  class SessionsConfiguredBehaviourTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous = {
        from: Bible270.config.mailer_from,
        after_out: Bible270.config.after_sign_out_path,
        log: Bible270.config.email_sign_in_log_link
      }
      Bible270.config.mailer_from = 'no-reply@example.org'
    end

    def teardown
      Bible270.config.mailer_from = @previous[:from]
      Bible270.config.after_sign_out_path = @previous[:after_out]
      Bible270.config.email_sign_in_log_link = @previous[:log]
      Bible270::Setting.open_enrollment!
    end

    def mount = Bible270.config.mount_at.chomp('/')

    def sign_in(email = 'r@example.org')
      _record, raw = Bible270::SignInToken.issue!(email, first_name: 'R', last_name: 'Reader')
      get "#{mount}/sign_in/email/#{raw}"
    end

    # Captures the log for the duration of the block. Swapping the logger is more
    # honest than stubbing a method on it: the code under test is free to log
    # however it likes.
    def captured_log
      previous = Rails.logger
      buffer = StringIO.new
      Rails.logger = ActiveSupport::Logger.new(buffer)
      yield
      buffer.string
    ensure
      Rails.logger = previous
    end

    def assert_logged(pattern, &) = assert_match(pattern, captured_log(&))
    def refute_logged(pattern, &) = refute_match(pattern, captured_log(&))

    def test_signing_out_honours_a_configured_destination
      Bible270.config.after_sign_out_path = '/goodbye'
      sign_in

      delete "#{mount}/sign_out"

      assert_equal '/goodbye', URI.parse(response.location).path
    end

    # A closed run must say so rather than failing silently, or the reader will
    # keep asking for links that can never work.
    def test_a_closed_run_explains_itself
      Bible270::Setting.close_enrollment!

      get "#{mount}/sign_in"

      assert_response :success
      assert_match(%r{closed}i, response.body)
    end

    # A token is still recorded — the response has to look identical either way, or
    # it reveals who already has an account. What must not happen is the mail.
    def test_a_closed_run_sends_no_link_to_a_newcomer
      Bible270::Setting.close_enrollment!
      ActionMailer::Base.deliveries.clear

      post "#{mount}/sign_in/email", params: { email: 'newcomer@example.org' }

      assert_empty ActionMailer::Base.deliveries, 'nobody new may be invited into a closed run'
    end

    def test_a_closed_run_still_sends_a_link_to_an_existing_reader
      Bible270::Reader.create!(provider: 'email', uid: 'old@example.org', email: 'old@example.org',
                               display_name: 'Old Hand')
      Bible270::Setting.close_enrollment!
      ActionMailer::Base.deliveries.clear

      post "#{mount}/sign_in/email", params: { email: 'old@example.org' }

      assert_equal 1, ActionMailer::Base.deliveries.size
    end

    # For local development without a working mail server. It defaults on in
    # development and test, and the flag can force it either way.
    def test_the_link_can_be_written_to_the_log
      Bible270.config.email_sign_in_log_link = true

      assert_logged(%r{sign-in link for dev@example\.org}) do
        post "#{mount}/sign_in/email", params: { email: 'dev@example.org' }
      end
    end

    def test_logging_the_link_can_be_turned_off
      Bible270.config.email_sign_in_log_link = false

      refute_logged(%r{sign-in link for quiet@example\.org}) do
        post "#{mount}/sign_in/email", params: { email: 'quiet@example.org' }
      end
    end

    # Delivery problems must not stop someone signing in — the token is issued
    # either way, and the failure is logged.
    def test_a_broken_mailer_does_not_break_the_request
      # A blank from address is the most realistic way to make delivery fail
      # without stubbing: Action Mailer raises on an empty sender.
      Bible270.config.mailer_from = ''

      post "#{mount}/sign_in/email", params: { email: 'unlucky@example.org' }

      assert_response :redirect
      assert_equal 1, Bible270::SignInToken.where(email: 'unlucky@example.org').count,
                   'the token is issued even when the mail cannot go out'
    end

    def test_an_unusable_address_is_refused_without_issuing_anything
      post "#{mount}/sign_in/email", params: { email: 'not-an-address' }

      assert_equal 0, Bible270::SignInToken.count
    end
  end
end
