# frozen_string_literal: true

require 'test_helper'

# The installer is the largest single untested piece, and the one a new user
# meets first. Run with --defaults so nothing prompts, and --no-bundle so it
# never shells out to bundler or rails.
if RAILS_LOADED
  require 'rails/generators'
  require 'rails/generators/test_case'
  require 'generators/bible270/install/install_generator'

  class InstallGeneratorTest < Rails::Generators::TestCase
    tests Bible270::Generators::InstallGenerator
    destination File.expand_path('../tmp/generator', __dir__)

    # The generator shells out to `bin/rails` for active_storage:install,
    # install:migrations and db:migrate. There is no bin/rails in a scratch
    # directory, so those calls fail noisily and pointlessly. Record them instead:
    # the test can then assert what the generator *would* run, which is worth more
    # than silencing them.
    class << self
      attr_accessor :shell_outs
    end

    # no_commands, because Thor treats every public method on a generator as a
    # command and reserves the name `run` — defining it plainly raises.
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

    # The minimum of a Rails app that the generator reads or writes.
    def build_host_app
      FileUtils.mkdir_p(File.join(destination_root, 'config'))
      FileUtils.mkdir_p(File.join(destination_root, 'db', 'migrate'))

      File.write(File.join(destination_root, 'config', 'routes.rb'), <<~RUBY)
        Rails.application.routes.draw do
          root to: "pages#home"
        end
      RUBY
      File.write(File.join(destination_root, 'config', 'application.rb'),
                 "module Host; class Application < Rails::Application; end; end\n")
      File.write(File.join(destination_root, 'Gemfile'), "source 'https://rubygems.org'\ngem 'rails'\n")

      # `rails new` writes this unless --skip-active-storage was used, and the
      # generator reads it to decide whether picture uploads are possible.
      File.write(File.join(destination_root, 'config', 'storage.yml'),
                 "local:\n  service: Disk\n  root: <%= Rails.root.join('storage') %>\n")
    end

    def test_it_writes_an_initializer_that_is_valid_ruby
      run_generator %w[--defaults --no-bundle]

      assert_file 'config/initializers/bible270.rb' do |content|
        assert_match(%r{Bible270\.configure do \|config\|}, content)
        assert_match(%r{config\.mount_at\s*=}, content)
        RubyVM::InstructionSequence.compile(content) # raises SyntaxError if not
      end
    end

    def test_it_mounts_the_engine
      run_generator %w[--defaults --no-bundle]

      assert_file 'config/routes.rb' do |content|
        assert_match(%r{mount Bible270::Engine}, content)
      end
    end

    def test_it_honours_a_custom_mount_point
      run_generator %w[--defaults --no-bundle --mount-at=/read270]

      assert_file 'config/initializers/bible270.rb', %r{config\.mount_at\s*=\s*'/read270'}
    end

    def test_it_can_mount_at_the_root
      run_generator %w[--defaults --no-bundle --mount-at=/]

      assert_file 'config/initializers/bible270.rb', %r{config\.mount_at\s*=\s*'/'}
    end

    def test_it_writes_an_omniauth_initializer_when_providers_are_chosen
      run_generator %w[--defaults --no-bundle --providers=github]

      assert_file 'config/initializers/omniauth.rb' do |content|
        assert_match(%r{OmniAuth::Builder}, content)
        assert_match(%r{provider :github}, content)
        # Builder has no path_prefix method; the option form is the correct one.
        refute_match(%r{^\s*path_prefix\s}, content)
        RubyVM::InstructionSequence.compile(content)
      end
    end

    def test_it_adds_the_strategy_gem
      run_generator %w[--defaults --no-bundle --providers=github]

      assert_file 'Gemfile', %r{omniauth-github}
    end

    def test_no_omniauth_initializer_without_providers
      run_generator %w[--defaults --no-bundle --providers= --email]

      assert_no_file 'config/initializers/omniauth.rb'
    end

    def test_it_installs_active_storage_and_runs_the_migrations
      run_generator %w[--defaults --providers=]

      commands = self.class.shell_outs
      assert_includes commands, 'active_storage:install', 'picture uploads need it'
      assert_includes commands, 'bible270:install:migrations'
      assert_includes commands, 'db:migrate'
    end

    def test_it_skips_active_storage_when_the_app_does_not_have_it
      # An app generated with --skip-active-storage has no config/storage.yml.
      FileUtils.rm_f(File.join(destination_root, 'config', 'storage.yml'))
      run_generator %w[--defaults --providers=]

      refute_includes self.class.shell_outs, 'active_storage:install'
      # ...but the engine's own migrations still run.
      assert_includes self.class.shell_outs, 'bible270:install:migrations'
    end

    def test_it_does_not_run_rails_after_adding_a_gem_it_has_not_bundled
      run_generator %w[--defaults --no-bundle --providers=github]

      # bin/rails cannot boot with an unbundled Gemfile, so the generator should
      # list those commands rather than attempt them.
      refute_includes self.class.shell_outs, 'db:migrate'
    end

    # ---- answering the questions -------------------------------------------
    #
    # Everything above runs with --defaults, which is not how a first-time user
    # meets the installer. Rails::Generators::TestCase feeds stdin, so the
    # prompts can be answered.

    def run_generator_answering(answers, args = %w[--no-bundle])
      Thor::LineEditor.stub(:readline, ->(*) { answers.shift.to_s }) do
        run_generator(args)
      end
    end

    def test_pressing_enter_at_every_prompt_gives_the_defaults
      # Empty answers mean "take the default" at each question.
      run_generator_answering(Array.new(12, ''))

      assert_file 'config/initializers/bible270.rb' do |content|
        assert_match(%r{config\.mount_at\s*=\s*'/daily-bread'}, content)
        RubyVM::InstructionSequence.compile(content)
      end
    end

    def test_a_mount_point_can_be_typed
      run_generator_answering(['/manna'] + Array.new(11, ''))

      assert_file 'config/initializers/bible270.rb', %r{config\.mount_at\s*=\s*'/manna'}
    end

    # A path with a space cannot be a mount point; the installer asks again rather
    # than writing something that will not route.
    def test_an_unusable_mount_point_is_asked_again
      run_generator_answering(['not a path', '/second-try'] + Array.new(11, ''))

      assert_file 'config/initializers/bible270.rb', %r{config\.mount_at\s*=\s*'/second-try'}
    end

    def test_declining_social_sign_in_writes_no_omniauth_initializer
      # mount, email?, from, social? -> no
      run_generator_answering(['', '', '', 'n'] + Array.new(9, ''))

      assert_no_file 'config/initializers/omniauth.rb'
      assert_file 'config/initializers/bible270.rb'
    end

    def test_providers_can_be_typed
      run_generator_answering(['', '', '', 'y', 'github'] + Array.new(8, ''))

      assert_file 'config/initializers/omniauth.rb', %r{provider :github}
      assert_file 'Gemfile', %r{omniauth-github}
    end

    # ---- what it tells you afterwards --------------------------------------

    def test_the_summary_names_what_it_did
      run_generator %w[--defaults --no-bundle]

      assert_match(%r{Plan mounted at}, output)
      assert_match(%r{/daily-bread}, output)
    end

    def test_it_lists_the_commands_it_could_not_run
      run_generator %w[--defaults --no-bundle]

      # It added a gem it has not bundled, so it cannot migrate for you.
      assert_match(%r{bundle install}, output)
      assert_match(%r{db:migrate}, output)
    end

    # The initializer reads credentials first and falls back to the environment,
    # so a host can use either without editing the file.
    def test_the_omniauth_initializer_names_both_credential_sources
      run_generator %w[--defaults --no-bundle --providers=github]

      assert_file 'config/initializers/omniauth.rb' do |content|
        assert_match(%r{credentials\.dig\(:github, :client_id\)}, content)
        assert_match(%r{GITHUB_CLIENT_ID}, content)
        assert_match(%r{GITHUB_CLIENT_SECRET}, content)
      end
    end

    def test_running_it_twice_does_not_duplicate_the_mount_line
      run_generator %w[--defaults --no-bundle]
      run_generator %w[--defaults --no-bundle --force]

      assert_file 'config/routes.rb' do |content|
        assert_equal 1, content.scan('mount Bible270::Engine').size
      end
    end
  end
end
