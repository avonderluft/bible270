# frozen_string_literal: true

require 'rails/generators'

module Bible270
  module Generators
    # Interactive installer:
    #
    #   bin/rails generate bible270:install
    #
    # Walks through the mount point, authentication, initializers, routing,
    # migrations and (optionally) running them. Every prompt has a default, so
    # holding Enter gives a working install. Pass --defaults to skip the prompts
    # entirely, or set any answer up front with a flag:
    #
    #   bin/rails generate bible270:install --defaults \
    #     --mount-at=/daily-bread --providers=github,google_oauth2 \
    #     --mailer-from=no-reply@example.org
    #
    class InstallGenerator < Rails::Generators::Base
      MOUNT_LINE        = 'mount Bible270::Engine, at: Bible270.config.mount_at'
      DEFAULT_MOUNT     = '/daily-bread'
      DEFAULT_PROVIDERS = 'github'
      KNOWN_PROVIDERS   = {
        'github' => 'omniauth-github',
        'google_oauth2' => 'omniauth-google-oauth2',
        'facebook' => 'omniauth-facebook',
        'twitter' => 'omniauth-twitter',
        'linkedin' => 'omniauth-linkedin-oauth2',
        'gitlab' => 'omniauth-gitlab',
        'discord' => 'omniauth-discord',
        'apple' => 'omniauth-apple',
        'saml' => 'omniauth-saml',
        'openid_connect' => 'omniauth_openid_connect'
      }.freeze

      class_option :mount_at,    type: :string,  desc: "Path to mount the engine at (default #{DEFAULT_MOUNT})"
      class_option :providers,   type: :string,  desc: 'Comma-separated OmniAuth providers, or "" for none'
      class_option :email,       type: :boolean, desc: 'Enable passwordless email sign-in'
      class_option :mailer_from, type: :string,  desc: 'From: address for sign-in emails'
      class_option :migrate,     type: :boolean, desc: 'Run db:migrate at the end'
      class_option :active_storage, type: :boolean,
                                    desc: 'Install Active Storage if missing (needed for picture uploads)'
      class_option :bundle,      type: :boolean, desc: 'Run bundle install after adding strategy gems'
      class_option :defaults,    type: :boolean, default: false, desc: 'Accept all defaults, ask nothing'

      # ---- 1. greeting ----------------------------------------------------

      def greet
        say ''
        say 'Installing bible270', :green
        say 'A 270-day Bible reading plan, mounted into this application.'
        say 'Press Enter to accept the [default] at any prompt.' unless quiet?
        say ''
      end

      # ---- 2. where to mount ----------------------------------------------

      def ask_mount_point
        @mount_at = normalize_mount(options[:mount_at] || prompt('Mount the plan at which path?', DEFAULT_MOUNT))

        until valid_mount?(@mount_at)
          say "  '#{@mount_at}' isn't a usable path.", :red
          @mount_at = normalize_mount(prompt('Mount the plan at which path?', DEFAULT_MOUNT))
        end

        say "  Plan will live at #{@mount_at}", :green
        say ''
      end

      # ---- 3. authentication ----------------------------------------------

      def ask_authentication
        say 'Authentication', :yellow
        say 'Readers must sign in to tick off readings and comment. Browsing is always public.'

        @email = decide(:email, 'Enable email sign-in (a one-time link, no password)?', true)
        @mailer_from = ask_mailer_from if @email

        @providers = decide_providers

        unless @email || @providers.any?
          say ''
          say '  No sign-in method chosen — readers would be unable to take part.', :red
          @email = confirm?('Enable email sign-in after all?', true)
        end

        # Covers the case where email was turned on by the question above.
        @mailer_from = ask_mailer_from if @email && @mailer_from.nil?

        report_auth_choice
        say ''
      end

      # ---- 4. strategy gems -------------------------------------------------

      def add_strategy_gems
        return if @providers.empty?

        missing = @providers.filter_map { |p| KNOWN_PROVIDERS[p] }.reject { |g| gemfile_has?(g) }
        unknown = @providers.reject { |p| KNOWN_PROVIDERS.key?(p) }

        missing.each { |name| gem name }

        return if unknown.empty?

        say "  Unrecognised provider(s): #{unknown.join(', ')}. Add their strategy gems yourself.", :yellow
      end

      def install_bundle
        return if @providers.empty?

        @bundled = decide(:bundle, 'Run bundle install now (needed before the app can boot)?', true)
        run 'bundle install' if @bundled
      end

      # ---- 5. Active Storage ------------------------------------------------
      #
      # Picture uploads need it. `rails new` enables the framework but the tables
      # come from a migration that must be installed, so check for that migration
      # rather than assuming a fresh app has it.

      def ensure_active_storage
        return if skip_rails_commands?

        unless active_storage_enabled?
          @active_storage = :unavailable
          say ''
          say '  Active Storage is not enabled here, so picture uploads will be off.', :yellow
          say '  (Was this app generated with --skip-active-storage?)'
          return
        end

        if active_storage_installed?
          @active_storage = :present
          say '  Active Storage already installed.', :green
          return
        end

        unless decide(:active_storage, 'Install Active Storage, so readers can upload a picture?', true)
          @active_storage = :declined
          return
        end

        say ''
        say 'Installing Active Storage', :yellow
        rails_command 'active_storage:install'
        @active_storage = :installed
      end

      # ---- 6. migrations ----------------------------------------------------

      # Migrations run before the initializers are written, so a problem in the
      # generated config can never block the database work.
      def copy_migrations
        return if skip_rails_commands?

        say ''
        say 'Copying migrations into db/migrate', :yellow
        rails_command 'bible270:install:migrations'
      end

      def run_migrations
        if skip_rails_commands?
          @migrated = false
          return
        end

        @migrated = decide(:migrate, 'Run the database migrations now?', true)

        if @migrated
          rails_command 'db:migrate'
        else
          say '  Skipped. Run bin/rails db:migrate when ready.', :yellow
        end
      end

      # ---- 7. initializers ---------------------------------------------------

      def create_engine_initializer
        create_file 'config/initializers/bible270.rb', engine_initializer
      end

      def create_omniauth_initializer
        return if @providers.empty?

        create_file 'config/initializers/omniauth.rb', omniauth_initializer
      end

      # ---- 8. routing -------------------------------------------------------

      def add_route
        if routes_mounted?
          say "  config/routes.rb already mounts Bible270::Engine — left as is.#{cms_order_hint}", :yellow
          return
        end

        route MOUNT_LINE

        # Thor's route action injects after the `Rails.application.routes.draw do`
        # sentinel and quietly does nothing if it can't find it (routes split
        # across files, an unusual layout, a missing file). Verify rather than
        # assume, since a silent miss leaves the plan unreachable.
        if routes_mounted?
          say "  Mounted in config/routes.rb.#{cms_order_hint}", :green
        else
          @route_failed = true
          say '  Could not edit config/routes.rb automatically.', :red
          say '  Add this line yourself, inside Rails.application.routes.draw:', :red
          say "    #{MOUNT_LINE}"
        end
      end

      # ---- 9. what is left to do -------------------------------------------

      def summary
        say ''
        say 'bible270 installed.', :green
        say ''
        say "  Plan mounted at   #{@mount_at}"
        say "  Sign-in           #{auth_summary}"
        say "  Initializers      #{initializer_summary}"
        say "  Migrations        #{@migrated ? 'copied and run' : 'copied (not yet run)'}"
        say "  Picture uploads   #{active_storage_summary}"
        say ''

        remaining = outstanding_steps
        if remaining.any?
          say 'Still to do:', :yellow
          remaining.each_with_index { |step, i| say "  #{i + 1}. #{step}" }
          say ''
        end

        say "Start the server and visit #{@mount_at}", :green
        say ''
      end

    private

      # Adding a gem to the Gemfile without bundling makes every subsequent
      # bin/rails call fail ("Could not find ... in locally installed gems"), so
      # don't even try.
      def skip_rails_commands?
        return false unless @providers.any? && @bundled == false
        return true if @warned_unbundled

        @warned_unbundled = true
        say ''
        say '  Gemfile changed but not bundled, so bin/rails cannot run yet.', :yellow
        say '  Skipping the migration steps — run these once you have bundled:', :yellow
        say '    bundle install'
        say '    bin/rails bible270:install:migrations'
        say '    bin/rails db:migrate'
        true
      end

      # config/storage.yml is written by `rails new` unless --skip-active-storage.
      def active_storage_enabled?
        return true if File.exist?(File.join(destination_root, 'config', 'storage.yml'))

        application = File.join(destination_root, 'config', 'application.rb')
        File.exist?(application) && File.read(application).include?('active_storage')
      rescue StandardError
        false
      end

      def active_storage_installed?
        Dir.glob(File.join(destination_root, 'db', 'migrate', '*create_active_storage_tables*')).any?
      end

      # ---- prompting --------------------------------------------------------

      def quiet? = options[:defaults]

      # Ask unless --defaults was passed or the answer came in as a flag.
      def prompt(question, default)
        return default if quiet?

        answer = ask("  #{question} [#{default}]")
        answer.to_s.strip.empty? ? default : answer.strip
      end

      # Deliberately not built on Thor's yes?, which treats a bare Enter as "no"
      # and is delegated to the shell (so wrapping ask here would never see it).
      # Reading the answer directly lets Enter mean "take the default", as the
      # [Y/n] hint implies.
      def confirm?(question, default)
        return default if quiet?

        suffix = default ? 'Y/n' : 'y/N'
        loop do
          answer = ask("  #{question} [#{suffix}]").to_s.strip.downcase
          return default if answer.empty?
          return true if %w[y yes].include?(answer)
          return false if %w[n no].include?(answer)

          say '  Please answer y or n.', :red
        end
      end

      # A boolean that may come from a flag, a prompt, or a default.
      def decide(key, question, default)
        return options[key] unless options[key].nil?

        confirm?(question, default)
      end

      def decide_providers
        if options[:providers]
          return parse_providers(options[:providers])
        end
        return parse_providers(DEFAULT_PROVIDERS) if quiet?

        return [] unless confirm?('Also offer social sign-in through OmniAuth?', true)

        list = prompt("Which providers? (comma separated, from: #{KNOWN_PROVIDERS.keys.join(', ')})",
                      DEFAULT_PROVIDERS)
        parse_providers(list)
      end

      def ask_mailer_from
        default = "no-reply@#{app_domain}"
        address = prompt('From: address for sign-in emails?', default)

        until valid_email?(address)
          say "  '#{address}' doesn't look like an email address.", :red
          address = prompt('From: address for sign-in emails?', default)
        end
        address
      end

      # Use the engine's own validator when it's loaded, else a simple check.
      def valid_email?(value)
        if defined?(Bible270::EmailSignIn)
          Bible270::EmailSignIn.valid_email?(value)
        else
          value.to_s.match?(%r{\A[^@\s]+@[^@\s]+\.[A-Za-z]{2,}\z})
        end
      end

      # ---- values -----------------------------------------------------------

      def normalize_mount(value)
        path = value.to_s.strip
        path = "/#{path}" unless path.start_with?('/')
        path = path.chomp('/')
        path.empty? ? '/' : path
      end

      def valid_mount?(path)
        path == '/' || path.match?(%r{\A(/[A-Za-z0-9\-_.~]+)+\z})
      end

      def parse_providers(value)
        value.to_s.split(',').map { |p| p.strip.downcase.tr('-', '_') }.reject(&:empty?).uniq
      end

      def app_domain
        name = Rails.application.class.module_parent_name.to_s
        name.empty? ? 'example.com' : "#{name.underscore.dasherize}.example.com"
      rescue StandardError
        'example.com'
      end

      def providers_literal
        @providers.map { |p| ":#{p}" }.join(', ')
      end

      def auth_path_prefix
        @mount_at == '/' ? '/auth' : "#{@mount_at}/auth"
      end

      def gemfile_has?(name)
        path = File.join(destination_root, 'Gemfile')
        File.exist?(path) && File.read(path).match?(%r{^\s*gem\s+['"]#{Regexp.escape(name)}['"]})
      end

      # A catch-all route (ComfortableMediaSurfer's `comfy_route :cms, path: '/'`
      # is the common one) will swallow requests for anything declared below it,
      # so the mount has to come first.
      def cms_order_hint
        path = File.join(destination_root, 'config', 'routes.rb')
        return '' unless File.exist?(path)

        body = File.read(path)
        return '' unless body.match?(%r{comfy_route|match\s+['"]\*|get\s+['"]\*})

        ' Check the mount line sits ABOVE any catch-all route.'
      end

      def routes_mounted?
        path = File.join(destination_root, 'config', 'routes.rb')
        File.exist?(path) && File.read(path).include?('Bible270::Engine')
      end

      def report_auth_choice
        say "  Email sign-in     #{@email ? 'on' : 'off'}", @email ? :green : nil
        say "  OmniAuth          #{@providers.any? ? @providers.join(', ') : 'off'}",
            @providers.any? ? :green : nil
      end

      def auth_summary
        parts = []
        parts << 'email link' if @email
        parts << "OmniAuth (#{@providers.join(', ')})" if @providers.any?
        parts.empty? ? 'none configured' : parts.join(' + ')
      end

      # What actually landed on disk. A pre-existing file the conflict prompt was
      # told not to overwrite would otherwise be reported as freshly written.
      def initializer_summary
        wrote = []
        wrote << 'bible270.rb' if initializer_present?('bible270.rb')
        wrote << 'omniauth.rb' if @providers.any? && initializer_present?('omniauth.rb')
        missing = []
        missing << 'bible270.rb' unless initializer_present?('bible270.rb')
        missing << 'omniauth.rb' if @providers.any? && !initializer_present?('omniauth.rb')

        summary = wrote.empty? ? 'none written' : wrote.join(' + ')
        summary += " (MISSING: #{missing.join(', ')})" if missing.any?
        summary
      end

      def initializer_present?(name)
        File.exist?(File.join(destination_root, 'config', 'initializers', name))
      end

      # An omniauth.rb from an earlier hand setup may pin a literal path_prefix
      # that no longer matches the mount point.
      def stale_omniauth_prefix?
        return false unless @providers.any? && initializer_present?('omniauth.rb')

        body = File.read(File.join(destination_root, 'config', 'initializers', 'omniauth.rb'))
        body.include?('path_prefix') && !body.include?('Bible270.config.auth_path_prefix')
      end

      def active_storage_summary
        case @active_storage
        when :installed then 'Active Storage installed'
        when :present then 'Active Storage already present'
        when :declined then 'off — Active Storage not installed'
        when :unavailable then 'off — Active Storage not enabled in this app'
        else 'unchanged'
        end
      end

      def outstanding_steps
        steps = []
        steps << "Add to config/routes.rb: #{MOUNT_LINE}" if @route_failed
        if @providers.any? && !initializer_present?('omniauth.rb')
          steps << 'Create config/initializers/omniauth.rb (see the README) — social sign-in will 404 without it'
        end
        if stale_omniauth_prefix?
          steps << "config/initializers/omniauth.rb sets its own path_prefix — make it 'Bible270.config.auth_path_prefix'"
        end
        steps << 'bundle install' if @providers.any? && !@bundled
        steps << 'bin/rails bible270:install:migrations' if skip_rails_commands?
        steps << 'bin/rails db:migrate' unless @migrated
        if @active_storage == :declined
          steps << 'bin/rails active_storage:install && bin/rails db:migrate — for picture uploads'
        end

        if @providers.any?
          steps << 'Set each provider\'s client id/secret in credentials or ENV'
          @providers.each { |p| steps << "Register callback URL: https://YOUR-HOST#{auth_path_prefix}/#{p}/callback" }
        end

        if @email
          steps << 'Confirm Action Mailer can deliver mail in this environment'
        end
        steps
      end

      # ---- file bodies ------------------------------------------------------

      def engine_initializer
        [initializer_head, indent(email_config_block), "\n",
         indent(omniauth_config_block), "\n", initializer_tail].join
      end

      def initializer_head
        <<~RUBY
          # frozen_string_literal: true

          # bible270 configuration.
          # Reference: https://github.com/avonderluft/bible270
          Bible270.configure do |config|
            # --- Where the plan lives -------------------------------------------------
            # Change this one value to move the plan. config/routes.rb and
            # config/initializers/omniauth.rb both read it, so nothing else needs editing
            # (but do update the callback URLs registered with each OAuth provider).
            config.mount_at = '#{@mount_at}'

            config.app_name = 'Daily Bread'
            config.tagline  = 'A 270-day journey through Scripture'

            # Share this application's layout, helpers and CSRF setup.
            config.parent_controller = '::ApplicationController'
            # config.layout = 'layouts/application'

            # --- Authentication -------------------------------------------------------
            # Viewing the plan is always public; ticking off and commenting need a reader.
            config.require_sign_in_to_participate = true

        RUBY
      end

      def initializer_tail
        <<~RUBY
            # --- Start date -----------------------------------------------------------
            # A community-wide start date, or leave nil for an undated plan.
            # config.start_date = Date.new(#{Date.today.year}, 1, 1)
            # Allow personal calendars, stamped when an undated reader first checks off.
            config.allow_reader_start_date = true

            # --- Daily reading reminders -----------------------------------------------
            # Readers choose an opt-in time only when enabled. This application owns
            # scheduling: run `bin/rails bible270:reminders:send` every 15 minutes.
            config.daily_reminders = false
            # config.mailer_host = 'example.com' # links back to the day and profile

            # --- Reading links --------------------------------------------------------
            config.bible_version = 'NKJV'
          end
        RUBY
      end

      def email_config_block
        if @email
          <<~RUBY
            # Passwordless email sign-in: a one-time link, no password, no third-party
            # account. This is what lets anyone take part. Needs Action Mailer delivery.
            config.email_sign_in = true
            config.mailer_from   = '#{@mailer_from}'
            config.email_sign_in_ask_name = true
            # config.email_sign_in_ttl = 20 * 60             # link lifetime, seconds
            # config.email_sign_in_max_per_window = 5        # per address, per window
            # config.email_sign_in_window = 15 * 60
            # config.email_sign_in_deliver_later = true      # needs an Active Job backend
          RUBY
        else
          <<~RUBY
            # Email sign-in is off. Turn it on to let readers without a social account
            # take part (it needs Action Mailer delivery and a from: address).
            config.email_sign_in = false
            # config.mailer_from = 'no-reply@example.com'
          RUBY
        end
      end

      def omniauth_config_block
        if @providers.any?
          <<~RUBY
            # Social sign-in. Strategy gems and credentials live in this application;
            # see config/initializers/omniauth.rb.
            config.omniauth_providers = [#{providers_literal}]
          RUBY
        else
          <<~RUBY
            # No social sign-in configured. Add providers here and register them in an
            # OmniAuth initializer to offer it.
            config.omniauth_providers = []
          RUBY
        end
      end

      def omniauth_initializer
        <<~RUBY
          # frozen_string_literal: true

          # OmniAuth middleware for bible270's social sign-in.
          #
          # path_prefix must match where the engine is mounted so OmniAuth's callback
          # (<prefix>/:provider/callback) lands on the engine's route. Rather than repeat
          # the path we read it from Bible270.config, which is set in
          # config/initializers/bible270.rb — Rails loads that first, because initializers
          # run in alphabetical order and 'bible270' precedes 'omniauth'.
          #
          # OmniAuth 2.0+ only allows POST to the request phase (CVE-2015-9284);
          # omniauth-rails_csrf_protection supplies the Rails-aware token check, and
          # bible270's sign-in controls are already POST forms.
          Rails.application.config.middleware.use OmniAuth::Builder do
            # Scope every provider below to the engine's mount point. `options` is
            # merged into each provider declared after it, so it has to come first.
            #
            # NB: OmniAuth::Builder has no `path_prefix` method — calling one raises
            # NoMethodError. `OmniAuth.config.path_prefix = ...` would also work, but
            # it is global and collides with Devise or any other OmniAuth user in
            # this app. A strategy reads `options[:path_prefix]` first, so this is
            # both correct and scoped.
            options path_prefix: Bible270.config.auth_path_prefix

          #{@providers.map { |p| indent(provider_line(p)) }.join("\n")}
          end

          # Send OmniAuth failures to the engine rather than raising.
          OmniAuth.config.on_failure = proc do |env|
            Bible270::SessionsController.action(:failure).call(env)
          end
        RUBY
      end

      # Indent every non-blank line, for slotting a block into a template.
      def indent(text, spaces = 2)
        text.gsub(%r{^(?!$)}, ' ' * spaces)
      end

      def provider_line(provider)
        env = provider.upcase
        <<~RUBY.chomp
          provider :#{provider},
                   Rails.application.credentials.dig(:#{provider}, :client_id) || ENV.fetch('#{env}_CLIENT_ID', nil),
                   Rails.application.credentials.dig(:#{provider}, :client_secret) || ENV.fetch('#{env}_CLIENT_SECRET', nil)
        RUBY
      end
    end
  end
end
