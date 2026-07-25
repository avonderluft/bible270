# frozen_string_literal: true
require "rails/generators"

module Bible270
  module Generators
    # rails generate bible270:install [--mount-at=/reading-plan] [--providers=github]
    #
    # Writes the engine initializer and an OmniAuth initializer whose path_prefix
    # matches the mount point (the one detail that is easy to get wrong).
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      class_option :mount_at, type: :string, default: "/reading-plan",
                   desc: "Path the engine is mounted at"
      class_option :providers, type: :string, default: "github",
                   desc: "Comma-separated OmniAuth providers (e.g. github,google_oauth2)"

      def create_initializers
        template "bible270.rb.tt", "config/initializers/bible270.rb"
        template "omniauth.rb.tt", "config/initializers/omniauth.rb"
      end

      def add_route
        route %(mount Bible270::Engine, at: "#{mount_at}")
      end

      def show_next_steps
        say ""
        say "bible270 installed.", :green
        say ""
        say "Next steps:"
        say "  1. Add the strategy gems to your Gemfile, e.g.:"
        provider_list.each { |p| say "       gem \"omniauth-#{p.tr('_', '-')}\"" }
        say "     plus:  gem \"omniauth\"  and  gem \"omniauth-rails_csrf_protection\""
        say "  2. bundle install"
        say "  3. bin/rails bible270:install:migrations && bin/rails db:migrate"
        say "  4. Set the provider credentials in your environment / credentials store."
        say "  5. Set config.mailer_from and make sure Action Mailer can deliver"
        say "     (email sign-in is what lets readers without a social account join)."
        say "  6. Register the callback URL with each provider:"
        provider_list.each { |p| say "       https://YOUR-HOST#{mount_at}/auth/#{p}/callback" }
        say ""
      end

      private

      def mount_at
        path = options[:mount_at].to_s
        path = "/#{path}" unless path.start_with?("/")
        path.chomp("/")
      end

      def provider_list
        options[:providers].to_s.split(",").map { |p| p.strip }.reject(&:empty?)
      end

      def providers_literal
        provider_list.map { |p| ":#{p}" }.join(", ")
      end

      def omniauth_path_prefix
        "#{mount_at}/auth"
      end
    end
  end
end
