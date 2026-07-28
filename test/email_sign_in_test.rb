# frozen_string_literal: true

require 'test_helper'
require 'bible270/email_sign_in'
require 'bible270/configuration'

class EmailSignInTest < Minitest::Test
  E = Bible270::EmailSignIn

  # --- normalization ------------------------------------------------------

  def test_normalizes_case_and_whitespace
    assert_equal 'andrew@example.com', E.normalize_email('  Andrew@Example.COM  ')
  end

  def test_strips_mailto_prefix
    assert_equal 'a@b.io', E.normalize_email('mailto:a@b.io')
    assert_equal 'a@b.io', E.normalize_email('MAILTO:A@B.IO')
  end

  def test_rejects_malformed_addresses
    ['', '   ', nil, 'bad', 'a@b', '@x.com', 'a@@b.com', 'a b@x.com',
     'a@x.c', 'a,b@x.com', 'a;b@x.com', '<a@x.com>'].each do |bad|
      assert_nil E.normalize_email(bad), "#{bad.inspect} should be rejected"
    end
  end

  def test_rejects_absurdly_long_addresses
    assert_nil E.normalize_email("#{'x' * 250}@example.com")
    assert E.valid_email?("#{'x' * 40}@example.com")
  end

  def test_accepts_ordinary_addresses
    ['a@b.io', 'first.last@sub.domain.org', 'user+tag@example.co.uk',
     'UPPER@EXAMPLE.COM', 'a_b-c@example.com'].each do |good|
      assert E.valid_email?(good), "#{good.inspect} should be accepted"
    end
  end

  # --- tokens -------------------------------------------------------------

  def test_tokens_are_long_random_and_url_safe
    tokens = 200.times.map { E.generate_token }
    assert_equal 200, tokens.uniq.size, 'tokens must not repeat'
    tokens.first(20).each do |t|
      assert t.length >= 40, "token too short: #{t.length}"
      assert_match(%r{\A[A-Za-z0-9_-]+\z}, t, 'token must be URL-safe')
    end
  end

  def test_digest_is_stable_hex_sha256
    token = E.generate_token
    assert_equal E.digest_token(token), E.digest_token(token)
    assert_equal 64, E.digest_token(token).length
    assert_match(%r{\A[0-9a-f]{64}\z}, E.digest_token(token))
  end

  def test_digest_does_not_leak_the_token
    token = E.generate_token
    refute_includes E.digest_token(token), token
  end

  def test_different_tokens_digest_differently
    assert E.digest_token('a') != E.digest_token('b')
  end

  def test_digest_of_nothing_is_nil
    assert_nil E.digest_token(nil)
    assert_nil E.digest_token('')
  end

  def test_secure_compare
    assert E.secure_compare('abcdef', 'abcdef')
    refute E.secure_compare('abcdef', 'abcdeg')
    refute E.secure_compare('abc', 'abcdef') # length mismatch
    refute E.secure_compare(nil, 'abc')
  end

  # --- display names ------------------------------------------------------

  def test_derives_a_display_name_from_the_local_part
    assert_equal 'Mary Anne Smith', E.display_name_from('mary.anne.smith@x.com')
    assert_equal 'Jo', E.display_name_from('jo@x.com')
    assert_equal 'Mary Anne Plan', E.display_name_from('mary-anne+plan@x.com')
    assert_equal 'A B', E.display_name_from('a_b@x.com')
  end

  def test_display_name_is_nil_for_invalid_addresses
    assert_nil E.display_name_from('nope')
    assert_nil E.display_name_from(nil)
  end
end

class EmailSignInConfigTest < Minitest::Test
  def setup
    @config = Bible270::Configuration.new
  end

  def test_email_sign_in_is_on_by_default
    assert @config.email_sign_in?
    assert @config.any_sign_in_method?
  end

  def test_ttl_and_rate_limit_defaults_are_sane
    assert_equal 20 * 60, @config.email_sign_in_ttl
    assert_equal 15 * 60, @config.email_sign_in_window
    assert_equal 5, @config.email_sign_in_max_per_window
    refute @config.email_sign_in_deliver_later
  end

  def test_email_only_deployment_is_possible
    @config.omniauth_providers = []
    assert @config.any_sign_in_method?, 'email alone must be a valid sign-in setup'
    refute @config.single_provider?
  end

  def test_omniauth_only_deployment_is_possible
    @config.email_sign_in = false
    assert @config.any_sign_in_method?
  end

  def test_no_method_configured_is_detectable
    @config.email_sign_in = false
    @config.omniauth_providers = []
    refute @config.any_sign_in_method?
  end
end
