# frozen_string_literal: true

# `uri` is a default gem on every supported Ruby. We deliberately avoid `cgi`
# here: the CGI library was removed from Ruby's default gems in Ruby 4.0 (only
# cgi/escape remains), so requiring it emits a deprecation warning there.
# URI.encode_www_form_component produces byte-identical output to CGI.escape.
require 'uri'
require 'bible270/plan'
require 'bible270/email_sign_in'
require 'bible270/avatars'
require 'bible270/translations'
require 'bible270/favicon'

module Bible270
  class Configuration
    # Controller the engine's controllers inherit from. Set this to your host's
    # "::ApplicationController" if you want to share layout, auth and helpers.
    attr_accessor :parent_controller

    # Layout used to render engine pages.
    attr_accessor :layout

    # A callable (lambda) that receives the current controller and returns a
    # Bible270::Reader (or nil). Use this to bridge your host's users:
    #
    #   config.current_reader_resolver = ->(c) {
    #     u = c.send(:current_user)
    #     u && Bible270::Reader.for_owner(u, display_name: u.name, email: u.email)
    #   }
    #
    # Leave nil to use the built-in session-based sign-in (OmniAuth).
    attr_accessor :current_reader_resolver

    # Where the engine is mounted in the host application. Set this once, in
    # config/initializers/bible270.rb, and use it everywhere the path is needed:
    #
    #   # config/routes.rb
    #   mount Bible270::Engine, at: Bible270.config.mount_at
    #
    #   # config/initializers/omniauth.rb
    #   path_prefix Bible270.config.auth_path_prefix
    #
    # Accepts "daily-bread" or "/daily-bread"; stored with a leading slash and
    # no trailing one.
    attr_reader :mount_at

    def mount_at=(value)
      path = value.to_s.strip
      path = "/#{path}" unless path.start_with?('/')
      path = path.chomp('/')
      @mount_at = path.empty? ? '/' : path
    end

    # The prefix OmniAuth's middleware should serve its routes under. Derived
    # from mount_at unless omniauth_path_prefix is set explicitly.
    def auth_path_prefix
      return omniauth_path_prefix if omniauth_path_prefix

      mount_at == '/' ? '/auth' : "#{mount_at}/auth"
    end

    # Where to send the reader after a successful sign-in / sign-out.
    attr_accessor :after_sign_in_path

    # ---- OmniAuth (built-in sign-in) --------------------------------------

    # Providers to offer on the sign-in screen. Accepts symbols, or pairs of
    # [provider, label] when you want to override the displayed name:
    #
    #   config.omniauth_providers = [:github]
    #   config.omniauth_providers = [:github, [:google_oauth2, "Google"]]
    #
    # The host application supplies the matching strategy gems and registers
    # them in the OmniAuth builder (see the README, or run the install generator).
    attr_reader :omniauth_providers

    # OmniAuth's path_prefix, if you need to override it. Normally leave this
    # nil: the engine derives "<mount point>/auth" from the request, which
    # matches a builder configured with path_prefix: "<mount point>/auth".
    attr_accessor :omniauth_path_prefix

    # Human labels for providers we know; anything else is titleised.
    PROVIDER_LABELS = {
      github: 'GitHub', gitlab: 'GitLab', google_oauth2: 'Google', google: 'Google',
      facebook: 'Facebook', twitter: 'Twitter', apple: 'Apple', discord: 'Discord',
      microsoft_graph: 'Microsoft', azure_activedirectory_v2: 'Microsoft',
      openid_connect: 'OpenID Connect', saml: 'SSO'
    }.freeze

    def omniauth_providers=(list)
      @omniauth_providers = Array(list).map do |entry|
        key, label = entry.is_a?(Array) ? entry : [entry, nil]
        key = key.to_sym
        [key, label || PROVIDER_LABELS[key] || key.to_s.tr('_', ' ').split.map(&:capitalize).join(' ')]
      end
    end

    def omniauth_provider_keys = omniauth_providers.map(&:first)

    # ---- Email sign-in (passwordless magic link) --------------------------

    # Offer sign-in by email link, so readers who don't have (or don't want to
    # use) a GitHub/Google/etc. account can still take part. Requires the host
    # app to have Action Mailer delivery configured.
    attr_accessor :email_sign_in

    # From: address for the sign-in email.
    attr_accessor :mailer_from

    # How long a magic link stays valid (seconds).
    attr_accessor :email_sign_in_ttl

    # Simple abuse guard: at most N links per address per window (seconds).
    attr_accessor :email_sign_in_window

    # Whether a reader may type the display name shown beside their reflections
    # when signing in by email (otherwise it's derived from the address).
    attr_accessor :email_sign_in_ask_name

    # Write the sign-in link to the log. nil (default) means development and test
    # only; true forces it on, for smoke-testing a production build locally
    # before mail is wired up; false disables it everywhere. The link is a bearer
    # credential, so true is not for a deployment real users can reach.
    attr_accessor :email_sign_in_log_link

    # Require a first AND last name when signing in by email. Names identify
    # people to each other beside their reflections, so this is on by default.
    attr_accessor :email_sign_in_require_name

    # Who may reach the admin panel. Either a list of email addresses, or a
    # lambda taking the current reader and returning true/false:
    #
    #   config.admin_emails = %w[andrew@example.org]
    #   config.admin_resolver = ->(reader) { reader.email.end_with?('@example.org') }
    #
    # With neither set the panel is unreachable and its routes 404.
    # Break points set from the host app, overriding Plan::CHAPTER_BREAKS.
    # Keys may be ['Psalm', 18] or 'Psalm 18'; [] keeps a chapter whole.
    # Largest avatar a reader may upload, in bytes. Uploading needs Active
    # Storage in the host app; without it the field is hidden and readers keep
    # whatever avatar their sign-in provider gave them.
    # Whether new readers may join this run of the plan. An admin can close it
    # from the panel at runtime; setting this to false launches closed.
    attr_accessor :enrollment_open

    # Favicon for the engine's pages. nil uses the built-in loaf, false renders
    # no link tag at all (so the host's own favicon applies), and a string is
    # used as the href — a path, a URL, or your own data URI.
    # Footer for the engine's pages. Three ways to set it, and they're checked in
    # this order:
    #
    #   config.footer_partial = 'shared/footer'   # a partial in your app
    #   config.footer_html    = '<p>…</p>'        # raw HTML, marked safe
    #   config.footer         = false             # no footer at all
    #
    # With none of them set you get the engine's own note about how the plan works.
    # Rails adds the leading underscore when looking a partial up, so
    # 'layouts/_bible270_footer' would search for '__bible270_footer' and raise
    # MissingTemplate. Accept either spelling and normalise.
    attr_reader :footer_partial

    def footer_partial=(path)
      @footer_partial =
        if path.nil?
          nil
        else
          segments = path.to_s.strip.split('/')
          segments[-1] = segments[-1].sub(%r{\A_}, '') unless segments.empty?
          segments.join('/')
        end
    end

    # Where your footer goes relative to the engine's own: :replace (default),
    # :after, or :before. Anything else is treated as :replace.
    attr_accessor :footer_placement

    PLACEMENTS = %i[replace after before].freeze

    def resolved_footer_placement
      placement = footer_placement.to_s.downcase.to_sym
      PLACEMENTS.include?(placement) ? placement : :replace
    end

    # Whether the engine's own footer is shown alongside yours.
    def keep_default_footer?
      footer_style != :none && %i[after before].include?(resolved_footer_placement)
    end

    # :none, :partial, :html or :default.
    def footer_style
      # Plain Ruby, not present?: this file has to load without ActiveSupport.
      return :none if footer == false
      return :partial unless footer_partial.to_s.strip.empty?
      return :html unless footer_html.to_s.strip.empty?

      :default
    end

    # Optional YAML file holding the same thing, re-read whenever it changes so
    # breaks can be tuned without restarting:
    #
    #   # config/bible270_breaks.yml
    #   Psalm 35: []
    #   Psalm 78: [20, 39, 55]
    attr_accessor :chapter_breaks_path

    def admin?(reader)
      return false if reader.nil?
      return !!admin_resolver.call(reader) if admin_resolver.respond_to?(:call)

      Array(admin_emails).map { |e| e.to_s.downcase }.include?(reader.email.to_s.downcase)
    end

    def admin_configured?
      admin_resolver.respond_to?(:call) || Array(admin_emails).any?
    end

    # Send the sign-in email via Active Job (deliver_later) instead of inline.
    # Leave false unless you have a queue backend configured.
    attr_accessor :email_sign_in_deliver_later

    def email_sign_in? = !!@email_sign_in

    # Reserved domains from RFC 2606 — a From: address at one of these will fail
    # SPF for your real domain, and receiving servers routinely drop it without
    # a bounce. The default value is one of them deliberately, so it has to be
    # changed, but nothing was checking that it had been.
    PLACEHOLDER_DOMAINS = %w[example.com example.org example.net example.edu invalid localhost].freeze

    # Why the sign-in mail is likely to vanish, or nil if it looks fine.
    def mailer_from_problem
      return nil unless email_sign_in?

      address = mailer_from.to_s.strip
      return 'config.mailer_from is blank' if address.empty?
      return "config.mailer_from (#{address}) is not a valid address" unless EmailSignIn.valid_email?(address)

      domain = address.split('@').last.to_s.downcase
      return nil unless PLACEHOLDER_DOMAINS.include?(domain)

      "config.mailer_from is still the placeholder #{address} — mail from a reserved domain " \
        'fails SPF and is usually dropped without a bounce'
    end

    # Any way at all for a new person to sign in?
    def any_sign_in_method?
      email_sign_in? || omniauth_providers.any?
    end

    def single_provider? = omniauth_providers.size == 1

    def label_for_provider(key)
      found = omniauth_providers.find { |k, _| k.to_s == key.to_s }
      return found.last if found

      PROVIDER_LABELS[key.to_sym] || key.to_s.tr('_', ' ').split.map(&:capitalize).join(' ')
    end

    # Default Bible translation and a builder for external passage links.
    # Which translations readers may choose from. Defaults to all of
    # Bible270::Translations::VERSIONS; narrow it to offer fewer.
    attr_accessor :bible_versions

    attr_accessor :after_sign_out_path, :email_sign_in_max_per_window, :passage_url_builder, :tagline, :footer_html, :footer, :favicon, :avatar_max_bytes, :chapter_breaks, :admin_emails, :admin_resolver, :bible_version

    # Public labels.
    attr_accessor :app_name

    # Optional community-wide start date for the plan. Set this when everyone
    # reads together as a cohort (e.g. a church starting on a set Sunday):
    #
    #   config.start_date = Date.new(2026, 9, 6)   # or the string "2026-09-06"
    #
    # Leave nil for an undated plan, where each reader's own start date applies
    # (defaulting to the day they first check something off).
    attr_reader :start_date

    # Whether an individual reader may set or change their own start date. When
    # false, everyone is pinned to config.start_date.
    attr_accessor :allow_reader_start_date

    # Only signed-in readers may check off and comment (viewing is always open).
    attr_accessor :require_sign_in_to_participate

    def initialize
      @parent_controller = 'ActionController::Base'
      @layout = 'bible270/application'
      @current_reader_resolver = nil
      @after_sign_in_path = nil
      @after_sign_out_path = nil
      @bible_version = 'NKJV'
      @bible_versions = Translations::VERSIONS.keys
      @passage_url_builder = ->(reference, version) do
        search  = URI.encode_www_form_component(reference)
        # Translations.gateway_code maps 'NASB95' to Bible Gateway's 'NASB1995'.
        version = URI.encode_www_form_component(Translations.gateway_code(version))
        "https://www.biblegateway.com/passage/?search=#{search}&version=#{version}"
      end
      @app_name = 'Daily Bread'
      @tagline = 'Journeying through Scripture in 9 months'
      @require_sign_in_to_participate = true
      self.mount_at = '/daily-bread'
      @start_date = nil
      @allow_reader_start_date = true
      self.omniauth_providers = [:github]
      @omniauth_path_prefix = nil
      @email_sign_in = true
      @mailer_from = 'no-reply@example.com'
      @email_sign_in_ttl = 20 * 60          # 20 minutes
      @email_sign_in_window = 15 * 60       # 15 minutes
      @email_sign_in_max_per_window = 5
      @email_sign_in_ask_name = true
      @email_sign_in_require_name = true
      @email_sign_in_log_link = nil
      @enrollment_open = true
      @footer_partial = nil
      @footer_placement = :replace
      @footer_html = nil
      @footer = nil
      @favicon = nil
      @avatar_max_bytes = Avatars::DEFAULT_MAX_BYTES
      @chapter_breaks = {}
      @chapter_breaks_path = nil
      @admin_emails = []
      @admin_resolver = nil
      @email_sign_in_deliver_later = false
    end

    # Accepts a Date, Time, or "YYYY-MM-DD" string.
    def start_date=(value)
      @start_date = Plan.to_date(value)
    end
  end

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end
  end
end
