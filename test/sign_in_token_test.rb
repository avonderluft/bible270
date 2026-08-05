# frozen_string_literal: true

require 'test_helper'

# Sign-in links are bearer credentials, so the properties worth pinning down are
# security ones: single use, expiry, only a digest stored, and a cap on how often
# one address can ask.
if RAILS_LOADED
  class SignInTokenTest < Minitest::Test
    T = Bible270::SignInToken

    def setup
      needs_rails!
      clear_engine_tables!
    end

    def test_issuing_returns_the_record_and_the_raw_token
      record, raw = T.issue!('reader@example.org')

      assert_kind_of T, record
      assert_kind_of String, raw
      assert_operator raw.length, :>=, 20, 'a guessable token would defeat the point'
    end

    def test_only_a_digest_is_stored
      _record, raw = T.issue!('reader@example.org')
      stored = T.last

      refute_equal raw, stored.token_digest
      assert_equal Bible270::EmailSignIn.digest_token(raw), stored.token_digest
      refute T.column_names.include?('token'), 'the raw token must never be persisted'
    end

    def test_the_address_is_normalised
      T.issue!('  Reader@Example.ORG ')

      assert_equal 'reader@example.org', T.last.email
    end

    def test_names_are_carried_through_to_the_reader
      _record, raw = T.issue!('reader@example.org', first_name: 'Andrew', last_name: 'vonderLuft')
      claimed = T.claim!(raw)

      assert_equal 'Andrew', claimed.first_name
      assert_equal 'vonderLuft', claimed.last_name
    end

    def test_claiming_consumes_the_token
      _record, raw = T.issue!('reader@example.org')

      assert T.claim!(raw)
      assert T.last.consumed?
      assert_nil T.claim!(raw), 'a second use must fail'
    end

    def test_an_unknown_token_is_not_claimable
      T.issue!('reader@example.org')

      assert_nil T.claim!('not-a-real-token')
      assert_nil T.claim!(nil)
      assert_nil T.claim!('')
    end

    def test_an_expired_token_is_not_claimable
      _record, raw = T.issue!('reader@example.org')
      T.last.update!(expires_at: 1.minute.ago)

      assert_nil T.claim!(raw)
    end

    def test_expiry_follows_the_configured_lifetime
      previous = Bible270.config.email_sign_in_ttl
      Bible270.config.email_sign_in_ttl = 15 * 60

      T.issue!('reader@example.org')

      assert_in_delta 15 * 60, T.last.expires_at - Time.current, 5
    ensure
      Bible270.config.email_sign_in_ttl = previous
    end

    def test_a_fresh_token_is_neither_expired_nor_consumed
      T.issue!('reader@example.org')
      token = T.last

      refute token.expired?
      refute token.consumed?
    end

    def test_expiry_is_reflected_in_the_predicate
      T.issue!('reader@example.org')
      token = T.last
      token.update!(expires_at: 1.second.ago)

      assert token.expired?
      refute token.consumed?, 'expiring is not consuming'
    end

    # Claiming an expired token must not consume it — it was never claimable, and
    # an earlier version of this test wrongly expected otherwise.
    def test_claiming_marks_a_live_token_consumed
      _record, raw = T.issue!('reader@example.org')

      refute_nil T.claim!(raw)
      assert T.last.consumed?
    end

    def test_the_live_scope_excludes_spent_and_stale_tokens
      _r1, live_raw = T.issue!('a@example.org')
      _r2, spent_raw = T.issue!('b@example.org')
      T.claim!(spent_raw)
      _r3, = T.issue!('c@example.org')
      T.find_by(email: 'c@example.org').update!(expires_at: 1.hour.ago)

      assert_equal 1, T.live.count
      assert_equal Bible270::EmailSignIn.digest_token(live_raw), T.live.first.token_digest
    end

    # Without a cap, the address becomes a way to send someone mail repeatedly.
    def test_asking_repeatedly_is_rate_limited
      limit = Bible270.config.email_sign_in_max_per_window

      refute T.rate_limited?('eager@example.org')
      limit.times { T.issue!('eager@example.org') }

      assert T.rate_limited?('eager@example.org')
      refute T.rate_limited?('someone.else@example.org'), 'the limit is per address'
    end

    def test_the_limit_is_case_insensitive
      limit = Bible270.config.email_sign_in_max_per_window
      limit.times { T.issue!('eager@example.org') }

      assert T.rate_limited?('EAGER@Example.org')
    end

    def test_sweeping_removes_old_tokens_and_keeps_live_ones
      _record, = T.issue!('fresh@example.org')
      T.issue!('stale@example.org')
      T.find_by(email: 'stale@example.org').update!(created_at: 30.days.ago, expires_at: 30.days.ago)

      T.sweep!

      assert_equal 1, T.count
      assert_equal 'fresh@example.org', T.first.email
    end

    def test_sweeping_takes_a_window
      T.issue!('recent@example.org')
      T.find_by(email: 'recent@example.org').update!(created_at: 2.days.ago, expires_at: 2.days.ago)

      T.sweep!(older_than: 7 * 24 * 60 * 60)
      assert_equal 1, T.count, 'two days old is inside the default window'

      T.sweep!(older_than: 60)
      assert_equal 0, T.count
    end
  end
end
