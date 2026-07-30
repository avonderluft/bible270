# frozen_string_literal: true

require 'test_helper'
require 'bible270/names'
require 'bible270/avatars'
require 'bible270/translations'
require 'bible270/favicon'
require 'bible270/plan'

# app/ code calls into the lib/ modules. A rename on one side and not the other
# only shows up as NoMethodError on whichever request touches it — which is how
# Names.split_display_name went missing after Names.split was renamed.
class LibModuleCallsTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  MODULES = {
    'Names' => Bible270::Names,
    'Avatars' => Bible270::Avatars,
    'Translations' => Bible270::Translations,
    'Favicon' => Bible270::Favicon,
    'Plan' => Bible270::Plan
  }.freeze

  def test_every_lib_module_method_called_from_app_code_exists
    sources = Dir.glob(File.join(ROOT, '{app,lib}/**/*.{rb,erb}'))
    missing = []

    MODULES.each do |name, mod|
      available = mod.singleton_methods.map(&:to_s)
      pattern = %r{(?:Bible270::)?#{name}\.([a-z_][a-z0-9_]*[?!]?)}

      sources.each do |file|
        File.read(file, encoding: 'UTF-8').scan(pattern).flatten.uniq.each do |method|
          next if available.include?(method)
          # constants and Ruby built-ins reached through the module are fine
          next if %w[new name to_s inspect respond_to? dig].include?(method)

          missing << "#{name}.#{method} — called in #{file.sub("#{ROOT}/", '')}"
        end
      end
    end

    assert_empty missing.uniq, <<~MSG
      These lib module methods are called but not defined, so the call raises
      NoMethodError at runtime:

      #{missing.uniq.join("\n      ")}
    MSG
  end
end
