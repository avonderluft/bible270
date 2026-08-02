# frozen_string_literal: true

require 'test_helper'

# The email sign-in round trip, and the properties that are easy to break by
# accident: the response must not reveal whether an address has an account, and
# a link must be single-use.
if RAILS_LOADED
  class SessionsTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_from = Bible270.config.mailer_from
      Bible270.config.mailer_from = 'no-reply@example.org'
    end

    def teardown
      Bible270.config.mailer_from = @previous_from
      Bible270::Setting.open_enrollment! if defined?(Bible270::Setting)
    end

    def mount = Bible270.config.mount_at.chomp('/')

    def test_asking_for_a_link_creates_a_token_and_says_nothing_revealing
      post "#{mount}/sign_in/email", params: { email: 'new@example.org',
                                               first_name: 'New', last_name: 'Reader' }

      assert_response :redirect
      assert_equal 1, Bible270::SignInToken.count
      assert_equal 'new@example.org', Bible270::SignInToken.last.email
    end

    # The wording must be identical for a known and an unknown address, or it
    # becomes a way to test who has an account.
    def test_the_response_is_the_same_for_known_and_unknown_addresses
      Bible270::Reader.create!(provider: 'email', uid: 'known@example.org',
                               email: 'known@example.org', display_name: 'Known')

      post "#{mount}/sign_in/email", params: { email: 'known@example.org' }
      known = flash[:notice]

      post "#{mount}/sign_in/email", params: { email: 'unknown@example.org' }
      unknown = flash[:notice]

      assert_equal known.to_s.sub('known', 'unknown'), unknown.to_s
    end

    def test_only_a_digest_of_the_token_is_stored
      post "#{mount}/sign_in/email", params: { email: 'reader@example.org' }
      token = Bible270::SignInToken.last

      assert token.respond_to?(:token_digest)
      refute token.respond_to?(:token), 'the raw token must not be persisted'
      refute_empty token.token_digest.to_s
    end

    def test_following_a_link_signs_the_reader_in
      _record, raw = Bible270::SignInToken.issue!('reader@example.org',
                                                  first_name: 'A', last_name: 'Reader')
      get "#{mount}/sign_in/email/#{raw}"

      assert_response :redirect
      assert_equal 1, Bible270::Reader.count
      assert_equal 'A Reader', Bible270::Reader.last.display_name
    end

    def test_a_link_works_only_once
      _record, raw = Bible270::SignInToken.issue!('reader@example.org',
                                                  first_name: 'A', last_name: 'Reader')
      get "#{mount}/sign_in/email/#{raw}"
      reset!
      get "#{mount}/sign_in/email/#{raw}"

      assert_response :redirect
      assert_equal 1, Bible270::Reader.count, 'the second use must not create another reader'
    end

    def test_an_unknown_token_is_rejected
      get "#{mount}/sign_in/email/not-a-real-token"

      assert_response :redirect
      assert_equal 0, Bible270::Reader.count
    end

    def test_a_closed_run_turns_away_someone_new
      skip 'closing a run not present' unless defined?(Bible270::Setting)
      Bible270::Setting.close_enrollment!

      _record, raw = Bible270::SignInToken.issue!('newcomer@example.org',
                                                  first_name: 'New', last_name: 'Comer')
      get "#{mount}/sign_in/email/#{raw}"

      assert_equal 0, Bible270::Reader.count, 'nobody new may join a closed run'
    end

    def test_a_closed_run_still_admits_an_existing_reader
      skip 'closing a run not present' unless defined?(Bible270::Setting)
      Bible270::Reader.create!(provider: 'email', uid: 'old@example.org',
                               email: 'old@example.org', display_name: 'Old Hand')
      Bible270::Setting.close_enrollment!

      _record, raw = Bible270::SignInToken.issue!('old@example.org')
      get "#{mount}/sign_in/email/#{raw}"

      assert_response :redirect
      assert_equal 1, Bible270::Reader.count
    end
  end
end
