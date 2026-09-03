# frozen_string_literal: true

require 'test_helper'

# Compile artifacts emitted by the production generator. This intentionally does
# not reproduce generator helpers or render dormant .tt files with a fake binding.
if RAILS_LOADED
  require 'rails/generators'
  require 'rails/generators/test_case'
  require 'generators/bible270/install/install_generator'

  class GeneratorTemplatesTest < Rails::Generators::TestCase
    tests Bible270::Generators::InstallGenerator
    destination File.expand_path('../tmp/generator_templates', __dir__)

    setup :prepare_destination
    setup :build_host_app

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
      File.write(File.join(destination_root, 'config', 'storage.yml'), "local:\n  service: Disk\n")
      File.write(File.join(destination_root, 'Gemfile'), "source 'https://rubygems.org'\ngem 'rails'\n")
    end

    def test_real_generator_outputs_compile_with_dynamic_values
      # The newly-added known provider plus --no-bundle prevents this scratch app
      # from attempting Rails commands, while still producing every artifact.
      run_generator [
        '--defaults', '--no-bundle', '--mount-at=/read-270',
        "--mailer-from=o'connor@example.org", '--providers=github,custom_sso'
      ]

      %w[
        config/initializers/bible270.rb
        config/initializers/omniauth.rb
        config/routes.rb
        Gemfile
      ].each do |path|
        assert_file path do |content|
          RubyVM::InstructionSequence.compile(content)
        rescue SyntaxError => e
          flunk "real generator produced invalid Ruby in #{path}: #{e.message.lines.first}"
        end
      end
    end
  end
end
