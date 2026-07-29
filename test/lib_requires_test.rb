# frozen_string_literal: true

require 'test_helper'

# Each file under lib/ must be requirable on its own. The app happened to work
# without this because lib/bible270.rb requires things in a lucky order, but a
# file that reaches for a constant it never required breaks the moment anything
# loads it directly — which the tests do, and so may a host app.
class LibRequiresTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  # engine.rb legitimately needs Rails, and lib/bible270.rb only requires it
  # when Rails::Engine is defined.
  SKIP = %w[engine].freeze

  def test_every_lib_file_loads_on_its_own
    files = Dir.glob(File.join(ROOT, 'lib/bible270/*.rb'))
      .map { |path| File.basename(path, '.rb') }
      .reject { |name| SKIP.include?(name) }

    refute_empty files

    # Requiring alone isn't enough: a constant referenced inside a method (as
    # Configuration#initialize referenced Avatars) loads fine and only blows up
    # when called. So instantiate the configuration too.
    probe = "require 'bible270/%s'; " \
            'Bible270::Configuration.new if defined?(Bible270::Configuration)'

    failures = files.reject do |name|
      system(RbConfig.ruby, '-I', File.join(ROOT, 'lib'), '-e', format(probe, name),
             out: File::NULL, err: File::NULL)
    end

    assert_empty failures, <<~MSG
      These files reference constants they don't require, so they only load when
      something else has already pulled the dependency in:

      #{failures.map { |name| "lib/bible270/#{name}.rb" }.join("\n      ")}
    MSG
  end
end
