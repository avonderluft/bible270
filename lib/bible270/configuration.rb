# frozen_string_literal: true

# `uri` is a default gem on every supported Ruby. We deliberately avoid `cgi`
# here: the CGI library was removed from Ruby's default gems in Ruby 4.0 (only
# cgi/escape remains), so requiring it emits a deprecation warning there.
# URI.encode_www_form_component produces byte-identical output to CGI.escape.
require "uri"
require "bible270/plan"

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
      path = "/#{path}" unless path.start_with?("/")
      path = path.chomp("/")
      @mount_at = path.empty? ? "/" : path
    end

    # The prefix OmniAuth's middleware should serve its routes under. Derived
    # from mount_at unless omniauth_path_prefix is set explicitly.
    def auth_path_prefix
      return omniauth_path_prefix if omniauth_path_prefix

      mount_at == "/" ? "/auth" : "#{mount_at}/auth"
    end

    # Where to send the reader after a successful sign-in / sign-out.
    attr_accessor :after_sign_in_path
    attr_accessor :after_sign_out_path

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
      github: "GitHub", gitlab: "GitLab", google_oauth2: "Google", google: "Google",
      facebook: "Facebook", twitter: "Twitter", apple: "Apple", discord: "Discord",
      microsoft_graph: "Microsoft", azure_activedirectory_v2: "Microsoft",
      openid_connect: "OpenID Connect", saml: "SSO"
    }.freeze

    def omniauth_providers=(list)
      @omniauth_providers = Array(list).map do |entry|
        key, label = entry.is_a?(Array) ? entry : [entry, nil]
        key = key.to_sym
        [key, (label || PROVIDER_LABELS[key] || key.to_s.tr("_", " ").split.map(&:capitalize).join(" "))]
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
    attr_accessor :email_sign_in_max_per_window

    # Whether a reader may type the display name shown beside their reflections
    # when signing in by email (otherwise it's derived from the address).
    attr_accessor :email_sign_in_ask_name

    # Send the sign-in email via Active Job (deliver_later) instead of inline.
    # Leave false unless you have a queue backend configured.
    attr_accessor :email_sign_in_deliver_later

    def email_sign_in? = !!@email_sign_in

    # Any way at all for a new person to sign in?
    def any_sign_in_method?
      email_sign_in? || omniauth_providers.any?
    end

    def single_provider? = omniauth_providers.size == 1

    def label_for_provider(key)
      found = omniauth_providers.find { |k, _| k.to_s == key.to_s }
      return found.last if found

      PROVIDER_LABELS[key.to_sym] || key.to_s.tr("_", " ").split.map(&:capitalize).join(" ")
    end

    # Default Bible translation and a builder for external passage links.
    attr_accessor :bible_version
    attr_accessor :passage_url_builder

    # Public labels.
    attr_accessor :app_name
    attr_accessor :tagline

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
      @parent_controller = "ActionController::Base"
      @layout = "bible270/application"
      @current_reader_resolver = nil
      @after_sign_in_path = nil
      @after_sign_out_path = nil
      @bible_version = "ESV"
      @passage_url_builder = lambda do |reference, version|
        search  = URI.encode_www_form_component(reference)
        version = URI.encode_www_form_component(version)
        "https://www.biblegateway.com/passage/?search=#{search}&version=#{version}"
      end
      @app_name = "Daily Bread"
      @tagline = "A 270-day journey through Scripture"
      @require_sign_in_to_participate = true
      self.mount_at = "/daily-bread"
      @start_date = nil
      @allow_reader_start_date = true
      self.omniauth_providers = [:github]
      @omniauth_path_prefix = nil
      @email_sign_in = true
      @mailer_from = "no-reply@example.com"
      @email_sign_in_ttl = 20 * 60          # 20 minutes
      @email_sign_in_window = 15 * 60       # 15 minutes
      @email_sign_in_max_per_window = 5
      @email_sign_in_ask_name = true
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
