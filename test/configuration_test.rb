# frozen_string_literal: true

require 'test_helper'
require 'bible270/configuration'

# Guards Ruby 4.0 compatibility: the CGI library was removed from Ruby's default
# gems in 4.0 (only cgi/escape remains), so the gem must not depend on it.
class ConfigurationTest < Minitest::Test
  def setup
    @config = Bible270::Configuration.new
  end

  # Ruby 4.0 moved a batch of libraries out of the default gems. Requiring one
  # from a gem that doesn't declare it passes everywhere except 4.0, so it
  # surfaces only on the newest CI row — or in production.
  #
  # Checked against the source rather than $LOADED_FEATURES: anything else in the
  # suite that loads ERB drags cgi/util in with it, which made the old version of
  # this test fail for reasons having nothing to do with the gem.
  MOVED_OUT_OF_STDLIB = %w[cgi rexml csv base64 bigdecimal drb observer abbrev
                           matrix prime rss getoptlong mutex_m].freeze

  # The engine may only lean on gems it declares. turbo_stream was used in nine
  # files while turbo-rails was undeclared, so any host without Turbo got a 500
  # on the first check-off.
  def test_frameworks_the_code_uses_are_declared_dependencies
    root = File.expand_path('..', __dir__)
    spec = Gem::Specification.load(File.join(root, 'bible270.gemspec'))
    declared = spec.dependencies.map(&:name)

    sources = Dir.glob(File.join(root, '{app,lib}/**/*.{rb,erb}')).map { |f| File.read(f) }.join

    { 'turbo-rails' => %r{turbo_stream}, 'omniauth' => %r{OmniAuth} }.each do |gem_name, pattern|
      next unless sources.match?(pattern)

      assert_includes declared, gem_name, "#{gem_name} is used but not declared in the gemspec"
    end
  end

  def test_does_not_require_libraries_ruby_4_dropped
    root = File.expand_path('..', __dir__)
    pattern = %r{^\s*require\s+['"](#{MOVED_OUT_OF_STDLIB.join('|')})(?:/[\w/]+)?['"]}

    offenders = Dir.glob(File.join(root, '{app,lib,test}/**/*.rb')).filter_map do |path|
      line = File.readlines(path).find { |l| l.match?(pattern) }
      "#{path.sub("#{root}/", '')}: #{line.strip}" if line
    end

    assert_empty offenders, <<~MSG
      These require libraries that are no longer default gems in Ruby 4.0:

      #{offenders.join("\n      ")}
    MSG
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

class FooterConfigTest < Minitest::Test
  def setup
    @config = Bible270::Configuration.new
  end

  def test_the_engines_own_footer_by_default
    assert_equal :default, @config.footer_style
  end

  def test_a_partial_wins_over_html
    @config.footer_html = '<p>html</p>'
    @config.footer_partial = 'shared/footer'
    assert_equal :partial, @config.footer_style
  end

  def test_raw_html_when_no_partial_is_given
    @config.footer_html = '<p>html</p>'
    assert_equal :html, @config.footer_style
  end

  def test_false_suppresses_the_footer_entirely
    @config.footer_partial = 'shared/footer'
    @config.footer = false
    assert_equal :none, @config.footer_style
  end

  def test_blank_values_are_ignored
    @config.footer_partial = '   '
    @config.footer_html = ''
    assert_equal :default, @config.footer_style
  end

  # Rails adds the underscore itself, so a configured '_footer' would be looked
  # up as '__footer' and raise MissingTemplate.
  def test_a_leading_underscore_is_stripped_from_the_partial_name
    @config.footer_partial = 'layouts/_bible270_footer'
    assert_equal 'layouts/bible270_footer', @config.footer_partial

    @config.footer_partial = '_footer'
    assert_equal 'footer', @config.footer_partial
  end

  def test_only_the_last_segment_is_touched
    @config.footer_partial = '_odd/dir/_footer'
    assert_equal '_odd/dir/footer', @config.footer_partial
  end

  def test_the_partial_name_is_trimmed_and_nil_stays_nil
    @config.footer_partial = '  shared/footer  '
    assert_equal 'shared/footer', @config.footer_partial

    @config.footer_partial = nil
    assert_nil @config.footer_partial
  end

  def test_placement_defaults_to_replacing
    assert_equal :replace, @config.resolved_footer_placement
    refute @config.keep_default_footer?
  end

  def test_after_and_before_keep_the_engines_footer
    @config.footer_html = '<p>mine</p>'
    %i[after before].each do |placement|
      @config.footer_placement = placement
      assert_equal placement, @config.resolved_footer_placement
      assert @config.keep_default_footer?, "#{placement} should keep the default footer"
    end
  end

  def test_placement_accepts_a_string
    @config.footer_html = '<p>mine</p>'
    @config.footer_placement = 'after'
    assert_equal :after, @config.resolved_footer_placement
  end

  def test_an_unknown_placement_falls_back_to_replacing
    @config.footer_html = '<p>mine</p>'
    @config.footer_placement = :sideways
    assert_equal :replace, @config.resolved_footer_placement
    refute @config.keep_default_footer?
  end

  def test_no_footer_wins_over_any_placement
    @config.footer_html = '<p>mine</p>'
    @config.footer_placement = :after
    @config.footer = false
    assert_equal :none, @config.footer_style
    refute @config.keep_default_footer?
  end
end

class MailerFromCheckTest < Minitest::Test
  def setup
    @config = Bible270::Configuration.new
  end

  def test_the_shipped_default_is_flagged
    # The generator writes a reserved-domain address on purpose; it must be
    # changed, and nothing used to check that it had been.
    assert_match(%r{placeholder}, @config.mailer_from_problem)
  end

  def test_a_real_address_passes
    @config.mailer_from = 'no-reply@gknt.org'
    assert_nil @config.mailer_from_problem
  end

  def test_blank_and_malformed_addresses_are_flagged
    @config.mailer_from = ''
    assert_match(%r{blank}, @config.mailer_from_problem)

    @config.mailer_from = 'not-an-address'
    assert_match(%r{not a valid address}, @config.mailer_from_problem)
  end

  def test_every_reserved_domain_is_flagged
    Bible270::Configuration::PLACEHOLDER_DOMAINS.each do |domain|
      @config.mailer_from = "no-reply@#{domain}"
      refute_nil @config.mailer_from_problem, "#{domain} should be flagged"
    end
  end

  def test_nothing_is_flagged_when_email_sign_in_is_off
    @config.email_sign_in = false
    assert_nil @config.mailer_from_problem
  end
end

class EnrollmentConfigTest < Minitest::Test
  def test_runs_are_open_by_default
    assert Bible270::Configuration.new.enrollment_open
  end

  def test_it_can_be_configured_to_launch_closed
    config = Bible270::Configuration.new
    config.enrollment_open = false
    refute config.enrollment_open
  end
end

class RegistrationNoticeConfigTest < Minitest::Test
  def setup
    @config = Bible270::Configuration.new
  end

  def test_notifications_are_off_by_default
    assert_empty @config.registration_notice_recipients
    refute @config.notify_on_registration?
  end

  def test_an_explicit_list_is_used_as_given
    @config.admin_emails = %w[admin@example.org]
    @config.registration_notice_emails = %w[secretary@example.org]

    # Deliberately not the admins: someone who isn't an admin can still be told.
    assert_equal %w[secretary@example.org], @config.registration_notice_recipients
  end

  def test_admins_follows_the_admin_list
    @config.admin_emails = ['Andrew@Example.org', 'second@x.io']
    @config.registration_notice_emails = :admins

    assert_equal %w[andrew@example.org second@x.io], @config.registration_notice_recipients
  end

  def test_admins_works_as_a_string_too
    @config.admin_emails = %w[a@b.io]
    @config.registration_notice_emails = 'admins'
    assert_equal %w[a@b.io], @config.registration_notice_recipients
  end

  def test_addresses_are_normalised_and_deduplicated
    @config.registration_notice_emails = ['Sec@Example.org', 'sec@example.org', ' sec@example.org ']
    assert_equal %w[sec@example.org], @config.registration_notice_recipients
  end

  def test_unusable_addresses_are_dropped_rather_than_mailed
    @config.registration_notice_emails = ['good@example.org', 'not-an-address', nil, '']
    assert_equal %w[good@example.org], @config.registration_notice_recipients
  end

  def test_a_bare_string_is_accepted
    @config.registration_notice_emails = 'one@x.io'
    assert_equal %w[one@x.io], @config.registration_notice_recipients
  end

  def test_admins_with_no_admins_configured_notifies_nobody
    @config.registration_notice_emails = :admins
    assert_empty @config.registration_notice_recipients
    refute @config.notify_on_registration?
  end

  def test_delivery_is_inline_unless_asked_otherwise
    refute @config.registration_notice_deliver_later
    assert_nil @config.mailer_host
  end
end

class AdminAccessTest < Minitest::Test
  Reader = Struct.new(:email)

  def setup
    @config = Bible270::Configuration.new
  end

  def test_nobody_is_an_admin_until_configured
    refute @config.admin_configured?
    refute @config.admin?(Reader.new('anyone@example.org'))
  end

  def test_an_email_list_grants_access_case_insensitively
    @config.admin_emails = ['Andrew@Example.org']

    assert @config.admin_configured?
    assert @config.admin?(Reader.new('andrew@example.org'))
    assert @config.admin?(Reader.new('ANDREW@EXAMPLE.ORG'))
    refute @config.admin?(Reader.new('someone@example.org'))
  end

  def test_a_resolver_takes_precedence_over_the_list
    @config.admin_emails = %w[listed@example.org]
    @config.admin_resolver = ->(reader) { reader.email.to_s.end_with?('@gknt.org') }

    assert @config.admin?(Reader.new('anyone@gknt.org'))
    refute @config.admin?(Reader.new('listed@example.org')), 'the resolver decides, not the list'
  end

  def test_a_nil_reader_is_never_an_admin
    @config.admin_emails = %w[andrew@example.org]
    refute @config.admin?(nil)

    @config.admin_resolver = ->(_reader) { true }
    refute @config.admin?(nil), 'a permissive resolver must still not admit nobody'
  end
end
