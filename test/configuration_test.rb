# frozen_string_literal: true

require 'test_helper'
require 'bible270/configuration'

# Guards Ruby 4.0 compatibility: the CGI library was removed from Ruby's default
# gems in 4.0 (only cgi/escape remains), so the gem must not depend on it.
class ConfigurationTest < Minitest::Test
  def setup
    @config = Bible270::Configuration.new
  end

  def test_does_not_load_the_cgi_library
    refute $LOADED_FEATURES.any? { |f| f =~ %r{/cgi(/util)?\.rb\z} },
           'bible270 must not require the cgi library (removed from default gems in Ruby 4.0)'
  end

  def test_default_passage_url_escapes_references
    url = @config.passage_url_builder.call("Genesis 1\u20133", 'NKJV')
    assert_equal 'https://www.biblegateway.com/passage/?search=Genesis+1%E2%80%933&version=NKJV', url
  end

  def test_default_passage_url_escapes_multi_book_references
    url = @config.passage_url_builder.call("Zechariah 14, Malachi 1\u20134", 'KJV')
    assert_includes url, 'search=Zechariah+14%2C+Malachi+1%E2%80%934'
    assert_includes url, 'version=KJV'
  end

  def test_split_chapter_reference_round_trips
    url = @config.passage_url_builder.call("Psalm 119:1\u201388", 'NKJV')
    assert_includes url, 'Psalm+119%3A1%E2%80%9388'
  end

  def test_sensible_defaults
    assert_equal 'ActionController::Base', @config.parent_controller
    assert_equal 'bible270/application', @config.layout
    assert_equal 'NKJV', @config.bible_version
    assert @config.require_sign_in_to_participate
    assert_nil @config.current_reader_resolver
  end
end

class ConfigurationStartDateTest < Minitest::Test
  def setup
    @config = Bible270::Configuration.new
  end

  def test_start_date_defaults_to_undated
    assert_nil @config.start_date
    assert @config.allow_reader_start_date, 'per-reader start dates should be allowed by default'
  end

  def test_start_date_accepts_a_date
    d = Date.new(2026, 9, 6)
    @config.start_date = d
    assert_equal d, @config.start_date
  end

  def test_start_date_accepts_a_string
    @config.start_date = '2026-09-06'
    assert_equal Date.new(2026, 9, 6), @config.start_date
    assert_kind_of Date, @config.start_date
  end

  def test_start_date_accepts_a_time
    @config.start_date = Time.new(2026, 9, 6, 9, 15)
    assert_equal Date.new(2026, 9, 6), @config.start_date
  end

  def test_garbage_start_date_becomes_nil_rather_than_raising
    @config.start_date = 'whenever'
    assert_nil @config.start_date
  end

  def test_start_date_can_be_cleared
    @config.start_date = '2026-09-06'
    @config.start_date = nil
    assert_nil @config.start_date
  end
end

class OmniAuthConfigTest < Minitest::Test
  def setup
    @config = Bible270::Configuration.new
  end

  def test_defaults_to_a_single_github_provider
    assert_equal [[:github, 'GitHub']], @config.omniauth_providers
    assert @config.single_provider?
    assert_equal [:github], @config.omniauth_provider_keys
    assert_nil @config.omniauth_path_prefix
  end

  def test_accepts_bare_symbols_and_labels_them
    @config.omniauth_providers = %i[github google_oauth2 gitlab]
    assert_equal [[:github, 'GitHub'], [:google_oauth2, 'Google'], [:gitlab, 'GitLab']],
                 @config.omniauth_providers
    refute @config.single_provider?
  end

  def test_accepts_explicit_label_overrides
    @config.omniauth_providers = [[:github, 'Our GitHub'], :saml]
    assert_equal [[:github, 'Our GitHub'], [:saml, 'SSO']], @config.omniauth_providers
  end

  def test_titleises_unknown_providers
    @config.omniauth_providers = [:my_custom_idp]
    assert_equal [[:my_custom_idp, 'My Custom Idp']], @config.omniauth_providers
  end

  def test_accepts_strings_and_a_single_value
    @config.omniauth_providers = 'github'
    assert_equal [[:github, 'GitHub']], @config.omniauth_providers
  end

  def test_label_for_provider_works_for_configured_and_unconfigured
    @config.omniauth_providers = [[:github, 'Our GitHub']]
    assert_equal 'Our GitHub', @config.label_for_provider(:github)
    assert_equal 'Our GitHub', @config.label_for_provider('github')
    # not in the list: falls back to the known-label table
    assert_equal 'Google', @config.label_for_provider(:google_oauth2)
  end

  def test_providers_can_be_emptied
    @config.omniauth_providers = []
    assert_empty @config.omniauth_providers
    refute @config.single_provider?
  end
end

class MountPointConfigTest < Minitest::Test
  def setup
    @config = Bible270::Configuration.new
  end

  def test_defaults_to_daily_bread
    assert_equal '/daily-bread', @config.mount_at
    assert_equal '/daily-bread/auth', @config.auth_path_prefix
  end

  def test_adds_a_leading_slash
    @config.mount_at = 'read270'
    assert_equal '/read270', @config.mount_at
    assert_equal '/read270/auth', @config.auth_path_prefix
  end

  def test_strips_trailing_slash_and_whitespace
    @config.mount_at = '  /reading-plan/  '
    assert_equal '/reading-plan', @config.mount_at
  end

  def test_nested_paths_are_preserved
    @config.mount_at = '/church/bible/plan'
    assert_equal '/church/bible/plan', @config.mount_at
    assert_equal '/church/bible/plan/auth', @config.auth_path_prefix
  end

  def test_mounting_at_root_does_not_double_the_slash
    @config.mount_at = '/'
    assert_equal '/', @config.mount_at
    assert_equal '/auth', @config.auth_path_prefix
  end

  def test_empty_value_becomes_root
    @config.mount_at = ''
    assert_equal '/', @config.mount_at
    assert_equal '/auth', @config.auth_path_prefix
  end

  def test_explicit_omniauth_prefix_overrides_the_derived_one
    @config.mount_at = '/read270'
    @config.omniauth_path_prefix = '/somewhere/else/auth'
    assert_equal '/somewhere/else/auth', @config.auth_path_prefix
    assert_equal '/read270', @config.mount_at, 'mount_at should be unaffected'
  end
end

# Guards a whole class of merge accident: code calling a config setting that was
# never added to Configuration, which only shows up as a NoMethodError at runtime
# on the request that happens to touch it.
class ConfigurationCompletenessTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  # Names that look like config calls but aren't ours: Rails' own config object,
  # OmniAuth DSL inside the generator's emitted templates, and plain Ruby.
  NOT_OURS = %w[
    middleware generators paths autoload_paths action_mailer x
    on_failure path_prefix respond_to? provider options
  ].freeze

  def test_every_config_method_the_code_calls_exists
    defined_methods = Bible270::Configuration.new.public_methods(false)
      .map(&:to_s).reject { |m| m.end_with?('=') }

    used = Dir.glob(File.join(ROOT, '{app,lib}/**/*.{rb,erb}')).flat_map do |file|
      File.read(file, encoding: 'UTF-8')
        .scan(%r{(?:Bible270\.config|config)\.([a-z_][a-z0-9_]*\??)})
        .flatten
        .map { |name| [name, file.sub("#{ROOT}/", '')] }
    end

    missing = used.reject { |name, _| defined_methods.include?(name) || NOT_OURS.include?(name) }
      .group_by(&:first)
      .map { |name, rows| "#{name} (called in #{rows.map(&:last).uniq.join(', ')})" }

    assert_empty missing, <<~MSG
      These settings are used but not defined on Bible270::Configuration:

      #{missing.join("\n      ")}
    MSG
  end
end
