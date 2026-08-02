# frozen_string_literal: true

require 'test_helper'
require 'erb'

class GeneratorTemplatesTest < Minitest::Test
  TEMPLATES = File.expand_path('../lib/generators/bible270/install/templates', __dir__)

  # Stands in for the generator's binding: same method names, same semantics.
  class FakeGenerator
    def initialize(mount, providers)
      (@mount = mount
       @providers = providers)
    end

    def mount_at
      path = @mount.to_s.strip
      path = "/#{path}" unless path.start_with?('/')
      path = path.chomp('/')
      path.empty? ? '/' : path
    end

    def provider_list = @providers.to_s.split(',').map(&:strip).reject(&:empty?)
    def providers_literal = provider_list.map { |p| ":#{p}" }.join(', ')
    def omniauth_path_prefix = mount_at == '/' ? '/auth' : "#{mount_at}/auth"
    def context = binding
  end

  def test_every_template_renders_to_valid_ruby
    templates = Dir.glob(File.join(TEMPLATES, '*.tt'))
    refute_empty templates

    [['/daily-bread', 'github'], ['/', 'github,google_oauth2'], ['read270/', '']].each do |mount, providers|
      generator = FakeGenerator.new(mount, providers)

      templates.each do |path|
        rendered = ERB.new(File.read(path), trim_mode: '-').result(generator.context)
        RubyVM::InstructionSequence.compile(rendered)
      rescue SyntaxError => e
        flunk "#{File.basename(path)} with mount #{mount.inspect} renders invalid Ruby: #{e.message.lines.first}"
      end
    end
  end
end
