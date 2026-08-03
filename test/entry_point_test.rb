# frozen_string_literal: true

require 'test_helper'

# lib/bible270.rb is the file a host app requires. It is nothing but requires,
# which makes it easy to forget one — twice this gem shipped a module that was
# defined but never loaded, and the failure only appeared on the request that
# touched it.
class EntryPointTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def test_requiring_the_gem_defines_every_module
    require 'bible270'

    %i[Plan Versification EmailSignIn Names Avatars Translations Favicon Configuration].each do |name|
      assert Bible270.const_defined?(name), "Bible270::#{name} should be loaded by require 'bible270'"
    end
  end

  # Checks that each file is *loaded*, not that the entry point names it —
  # versification arrives through plan.rb, which is fine. A file nothing loads is
  # dead weight: lib/bible270/bible270.rb was a stray duplicate of the entry point
  # for exactly this reason, shipped in the gem and never once required.
  def test_every_library_file_is_reachable_from_the_entry_point
    require 'bible270'

    loaded = $LOADED_FEATURES.map { |path| File.expand_path(path) }
    files = Dir.glob(File.join(ROOT, 'lib/bible270/*.rb'))
      .reject { |path| File.basename(path) == 'engine.rb' } # only under Rails

    orphans = files.reject { |path| loaded.include?(File.expand_path(path)) }

    assert_empty orphans.map { |path| path.sub("#{ROOT}/", '') },
                 'these files are never loaded — either require them or delete them'
  end

  def test_the_engine_is_loaded_only_when_rails_is_present
    entry = File.read(File.join(ROOT, 'lib/bible270.rb'))

    assert_match(%r{require 'bible270/engine' if defined\?\(Rails::Engine\)}, entry,
                 'the engine must not be required outside Rails')
  end

  def test_the_version_is_a_release_number
    require 'bible270/version'

    assert_match(%r{\A\d+\.\d+\.\d+}, Bible270::VERSION)
  end
end
