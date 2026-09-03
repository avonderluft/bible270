# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  require 'rails/generators'
  require 'rails/generators/test_case'
  require 'generators/bible270/install/install_generator'

  class InstallGeneratorTest < Rails::Generators::TestCase
    tests Bible270::Generators::InstallGenerator
    destination File.expand_path('../tmp/generator', __dir__)

    class << self
      attr_accessor :shell_outs
    end

    # A scratch destination has no bin/rails. Record external commands so tests
    # can assert both whether they run and their production ordering.
    Bible270::Generators::InstallGenerator.class_eval do
      no_commands do
        def rails_command(command, *_args, **_opts)
          InstallGeneratorTest.shell_outs << command
          nil
        end

        def run(command, *_args, **_opts)
          InstallGeneratorTest.shell_outs << command
          nil
        end
      end
    end

    setup :prepare_destination
    setup :build_host_app
    setup { self.class.shell_outs = [] }

    def build_host_app
      FileUtils.mkdir_p(File.join(destination_root, 'config'))
      FileUtils.mkdir_p(File.join(destination_root, 'db', 'migrate'))

      write_routes <<~RUBY
        Rails.application.routes.draw do
          root to: "pages#home"
        end
      RUBY
      File.write(File.join(destination_root, 'config', 'application.rb'),
                 "module Host; class Application < Rails::Application; end; end\n")
      File.write(File.join(destination_root, 'Gemfile'), "source 'https://rubygems.org'\ngem 'rails'\n")
      File.write(File.join(destination_root, 'config', 'storage.yml'),
                 "local:\n  service: Disk\n  root: <%= Rails.root.join('storage') %>\n")
    end

    def write_routes(content)
      File.write(File.join(destination_root, 'config', 'routes.rb'), content)
    end

    def assert_valid_ruby(path)
      assert_file path do |content|
        RubyVM::InstructionSequence.compile(content)
      rescue SyntaxError => e
        flunk "#{path} is invalid Ruby: #{e.message.lines.first}"
      end
    end

    # ---- generated Ruby and option values ----------------------------------

    def test_generated_initializers_are_valid_ruby
      run_generator %w[--defaults --no-bundle]

      assert_file 'config/initializers/bible270.rb' do |content|
        assert_match(%r{Bible270\.configure do \|config\|}, content)
        assert_match(%r{config\.daily_reminders\s*=\s*false}, content)
        assert_match(%r{bible270:reminders:send}, content)
        RubyVM::InstructionSequence.compile(content)
      end
      assert_valid_ruby 'config/initializers/omniauth.rb'
    end

    def test_mailer_from_option_is_honoured_and_safely_quoted
      run_generator ['--defaults', '--providers=', "--mailer-from=o'connor@example.org"]

      assert_file 'config/initializers/bible270.rb' do |content|
        assert_includes content, %(config.mailer_from   = "o'connor@example.org")
        RubyVM::InstructionSequence.compile(content)
      end
    end

    def test_custom_and_root_mount_points_are_generated_as_valid_literals
      run_generator %w[--defaults --providers= --mount-at=/read270]
      assert_file 'config/initializers/bible270.rb', %r{config\.mount_at\s*=\s*"/read270"}
      assert_valid_ruby 'config/initializers/bible270.rb'

      prepare_destination
      build_host_app
      self.class.shell_outs = []
      run_generator %w[--defaults --providers= --mount-at=/]
      assert_file 'config/initializers/bible270.rb', %r{config\.mount_at\s*=\s*"/"}
      assert_valid_ruby 'config/initializers/bible270.rb'
    end

    # ---- provider contract and Gemfile behavior -----------------------------

    def test_multiple_providers_are_normalized_deduplicated_and_compile
      run_generator %w[--defaults --no-bundle --providers=github,google-oauth2,github,GOOGLE_OAUTH2]

      assert_file 'config/initializers/bible270.rb' do |content|
        assert_equal 1, content.scan(':github').size
        assert_equal 1, content.scan(':google_oauth2').size
        RubyVM::InstructionSequence.compile(content)
      end
      assert_file 'config/initializers/omniauth.rb' do |content|
        assert_equal 3, content.scan(':github').size,
                     'provider plus the two credential lookups should use the provider symbol'
        assert_equal 3, content.scan(':google_oauth2').size
        RubyVM::InstructionSequence.compile(content)
      end
      assert_file 'Gemfile' do |content|
        assert_equal 1, content.scan(%r{gem ['"]omniauth-github['"]}).size
        assert_equal 1, content.scan(%r{gem ['"]omniauth-google-oauth2['"]}).size
      end
    end

    def test_valid_unknown_provider_generates_valid_ruby_and_actionable_warning
      printed = run_generator %w[--defaults --providers=custom_sso]

      assert_match(%r{Unrecognised provider.*custom_sso}, printed)
      assert_match(%r{strategy gem that registers :custom_sso.*Gemfile.*bundle install}m, printed)
      assert_file 'config/initializers/bible270.rb', %r{config\.omniauth_providers = \[:custom_sso\]}
      assert_file 'config/initializers/omniauth.rb', %r{provider :custom_sso}
      assert_valid_ruby 'config/initializers/bible270.rb'
      assert_valid_ruby 'config/initializers/omniauth.rb'
      refute_includes File.read(File.join(destination_root, 'Gemfile')), 'omniauth-custom_sso'
    end

    def test_unsafe_provider_identifiers_are_reported_and_skipped
      printed = run_generator [
        '--defaults', '--no-bundle',
        "--providers=github,bad provider,9starts_with_number,evil'provider,custom_sso"
      ]

      assert_match(%r{Ignoring unsafe provider identifier}, printed)
      assert_match(%r{bad provider}, printed)
      assert_match(%r{9starts_with_number}, printed)
      assert_match(%r{only lowercase letters, numbers, and underscores}, printed)
      assert_file 'config/initializers/bible270.rb' do |content|
        assert_includes content, '[:github, :custom_sso]'
        refute_includes content, 'bad provider'
        refute_includes content, "evil'provider"
        RubyVM::InstructionSequence.compile(content)
      end
      assert_valid_ruby 'config/initializers/omniauth.rb'
    end

    def test_gemfile_changes_are_idempotent
      args = %w[--defaults --no-bundle --providers=github,google_oauth2]
      run_generator args
      run_generator args + ['--force']

      assert_file 'Gemfile' do |content|
        assert_equal 1, content.scan(%r{gem ['"]omniauth-github['"]}).size
        assert_equal 1, content.scan(%r{gem ['"]omniauth-google-oauth2['"]}).size
      end
    end

    # ---- authentication combinations ---------------------------------------

    def test_email_only_configuration
      run_generator ['--defaults', '--providers=', '--email', '--mailer-from=reader@example.org']

      assert_no_file 'config/initializers/omniauth.rb'
      assert_file 'config/initializers/bible270.rb' do |content|
        assert_includes content, 'config.email_sign_in = true'
        assert_includes content, 'config.omniauth_providers = []'
        assert_includes content, 'config.mailer_from   = "reader@example.org"'
      end
    end

    def test_social_only_configuration
      run_generator %w[--defaults --no-bundle --no-email --providers=github]

      assert_file 'config/initializers/bible270.rb' do |content|
        assert_includes content, 'config.email_sign_in = false'
        assert_includes content, 'config.omniauth_providers = [:github]'
      end
      assert_file 'config/initializers/omniauth.rb', %r{provider :github}
    end

    def test_safety_fallback_enables_email_when_no_sign_in_method_is_chosen
      printed = run_generator %w[--defaults --no-email --providers=]

      assert_match(%r{No sign-in method chosen}, printed)
      assert_file 'config/initializers/bible270.rb' do |content|
        assert_includes content, 'config.email_sign_in = true'
        assert_includes content, 'config.omniauth_providers = []'
      end
    end

    # ---- external command policy and truthful summary -----------------------

    def test_no_bundle_after_adding_provider_runs_no_rails_commands_and_lists_all_steps
      printed = run_generator %w[--defaults --no-bundle --providers=github]

      assert_empty self.class.shell_outs
      assert_match(%r{Migrations\s+not copied \(not run\)}, printed)
      expected = [
        'bundle install',
        'bin/rails active_storage:install',
        'bin/rails bible270:install:migrations',
        'bin/rails db:migrate'
      ]
      positions = expected.map do |command|
        assert_includes printed, command
        printed.index(command)
      end
      assert_equal positions.sort, positions, 'outstanding commands should be shown in runnable order'
    end

    def test_provider_bundle_success_runs_commands_in_boot_safe_order
      # Rails' test helper always appends --skip-bundle, so invoke the real class
      # directly for the production --bundle path.
      capture(:stdout) do
        Bible270::Generators::InstallGenerator.start(
          %w[--defaults --bundle --providers=github], destination_root: destination_root
        )
      end

      assert_equal [
        'bundle install',
        'active_storage:install',
        'bible270:install:migrations',
        'db:migrate'
      ], self.class.shell_outs
    end

    def test_no_migrate_copies_but_does_not_run_migrations
      printed = run_generator %w[--defaults --providers= --no-migrate]

      assert_equal ['active_storage:install', 'bible270:install:migrations'], self.class.shell_outs
      assert_match(%r{Migrations\s+copied \(not yet run\)}, printed)
      assert_includes printed, 'bin/rails db:migrate'
    end

    def test_existing_active_storage_is_not_installed_again
      File.write(File.join(destination_root, 'db', 'migrate', '20260902000000_create_active_storage_tables.rb'), '')
      printed = run_generator %w[--defaults --providers=]

      assert_equal ['bible270:install:migrations', 'db:migrate'], self.class.shell_outs
      assert_match(%r{Active Storage already installed}, printed)
      assert_match(%r{Picture uploads\s+Active Storage already present}, printed)
    end

    def test_no_active_storage_skips_install_but_runs_engine_migrations
      printed = run_generator %w[--defaults --providers= --no-active-storage]

      assert_equal ['bible270:install:migrations', 'db:migrate'], self.class.shell_outs
      assert_match(%r{Picture uploads\s+off — Active Storage not installed}, printed)
      assert_includes printed, 'bin/rails active_storage:install && bin/rails db:migrate'
    end

    def test_app_without_active_storage_still_runs_engine_migrations
      FileUtils.rm_f(File.join(destination_root, 'config', 'storage.yml'))
      run_generator %w[--defaults --providers=]

      assert_equal ['bible270:install:migrations', 'db:migrate'], self.class.shell_outs
    end

    # ---- routing -------------------------------------------------------------

    def test_comment_mentioning_engine_does_not_count_as_a_mount
      write_routes <<~RUBY
        Rails.application.routes.draw do
          # Mount Bible270::Engine here after deciding where it belongs.
          root to: "pages#home"
        end
      RUBY

      run_generator %w[--defaults --providers=]

      assert_file 'config/routes.rb' do |content|
        assert_equal 1, content.scan(%r{^\s*mount Bible270::Engine}).size
        assert_includes content, '# Mount Bible270::Engine here'
        RubyVM::InstructionSequence.compile(content)
      end
    end

    def test_mount_is_placed_above_a_catch_all_route
      write_routes <<~RUBY
        Rails.application.routes.draw do
          comfy_route :cms, path: '/'
        end
      RUBY

      run_generator %w[--defaults --providers=]

      routes = File.read(File.join(destination_root, 'config', 'routes.rb'))
      assert_operator routes.index('mount Bible270::Engine'), :<, routes.index('comfy_route')
    end

    def test_existing_mount_below_catch_all_is_moved_above_it
      write_routes <<~RUBY
        Rails.application.routes.draw do
          get '*path', to: 'pages#show'
          mount Bible270::Engine, at: Bible270.config.mount_at
        end
      RUBY

      printed = run_generator %w[--defaults --providers=]

      routes = File.read(File.join(destination_root, 'config', 'routes.rb'))
      assert_operator routes.index('mount Bible270::Engine'), :<, routes.index("get '*path'")
      assert_match(%r{moved it above the catch-all route}, printed)
    end

    def test_route_injection_failure_prints_the_exact_manual_fix
      write_routes "# Routes are loaded from another file\n"

      printed = run_generator %w[--defaults --providers=]

      assert_match(%r{Could not edit config/routes\.rb automatically}, printed)
      assert_includes printed, 'Add this line yourself, inside Rails.application.routes.draw:'
      assert_includes printed, 'mount Bible270::Engine, at: Bible270.config.mount_at'
      assert_match(%r{Still to do:.*Add to config/routes\.rb: mount Bible270::Engine}m, printed)
      assert_file 'config/routes.rb' do |content|
        refute_match(%r{^\s*mount Bible270::Engine}, content)
      end
    end

    def test_running_twice_does_not_duplicate_the_mount
      run_generator %w[--defaults --no-bundle]
      run_generator %w[--defaults --no-bundle --force]

      assert_file 'config/routes.rb' do |content|
        assert_equal 1, content.scan(%r{^\s*mount Bible270::Engine}).size
      end
    end

    # ---- interactive defaults ------------------------------------------------

    def run_generator_answering(answers, args = %w[--no-bundle])
      Thor::LineEditor.stub(:readline, ->(*) { answers.shift.to_s }) do
        run_generator(args)
      end
    end

    def test_pressing_enter_at_every_prompt_uses_safe_defaults
      run_generator_answering(Array.new(12, ''))

      assert_file 'config/initializers/bible270.rb' do |content|
        assert_includes content, 'config.mount_at = "/daily-bread"'
        assert_includes content, 'config.email_sign_in = true'
        assert_includes content, 'config.omniauth_providers = [:github]'
        RubyVM::InstructionSequence.compile(content)
      end
    end

    def test_invalid_interactive_mount_is_asked_again
      run_generator_answering(['not a path', '/second-try'] + Array.new(11, ''))

      assert_file 'config/initializers/bible270.rb', %r{config\.mount_at\s*=\s*"/second-try"}
    end
  end
end
