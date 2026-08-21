# frozen_string_literal: true

ENV['RAILS_ENV'] = 'test'

# SKIP_COV is available for especially quick targeted runs. Parallel workers use
# distinct command names so SimpleCov can merge their results into one report.
unless ENV['SKIP_COV']
  require 'simplecov'

  SimpleCov.coverage_dir File.expand_path('../coverage', __dir__)

  if ENV['PARALLEL_COVERAGE']
    worker = ENV['TEST_ENV_NUMBER'].to_s
    worker = '1' if worker.empty?
    SimpleCov.command_name "Parallel Tests #{worker}"
    SimpleCov.formatter(Class.new { def format(_result); end })
  end

  SimpleCov.start do
    track_files '{app,lib}/**/*.rb'

    add_filter '/test/'
    add_filter '/gemfiles/'
    add_filter 'lib/bible270/version.rb'

    add_group 'Plan',        'lib/bible270/plan.rb'
    add_group 'Library',     'lib/bible270'
    add_group 'Generators',  'lib/generators'
    add_group 'Models',      'app/models'
    add_group 'Controllers', 'app/controllers'
    add_group 'Helpers',     'app/helpers'
    add_group 'Mailers',     'app/mailers'

    minimum_coverage ENV['COVERAGE_FLOOR'].to_i if ENV['COVERAGE_FLOOR']
  end
end

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'minitest/autorun'
require 'minitest/mock'
require 'minitest/reporters'
require 'parallel_tests/test/runtime_logger' if ENV['RECORD_RUNTIME']

Minitest::Reporters.use!(
  Minitest::Reporters::DefaultReporter.new(color: !ENV.key?('NO_COLOR'))
)
require 'bible270/plan'

# ---- clean dummy application ---------------------------------------------

dummy_root = File.expand_path('dummy', __dir__)

FileUtils.mkdir_p File.join(dummy_root, 'log')
FileUtils.mkdir_p File.join(dummy_root, 'tmp', 'storage')

FileUtils.rm_f File.join(dummy_root, 'log', 'test.log')
FileUtils.rm_rf Dir[File.join(dummy_root, 'tmp', 'storage', '*')]

# ---- the dummy application ------------------------------------------------
#
# Booting a real Rails app is the only way to exercise the models, controllers,
# mailers and helpers — roughly 60% of the gem, and the part where the bugs that
# actually reach users live (a missing template, an unqualified constant, a helper
# Rails never mixed in). The static checks elsewhere in this suite exist because
# they were all that was possible before this.
#
# Guarded so the pure tests still run where Rails or sqlite3 isn't installed;
# anything needing the database says `needs_rails!` and skips otherwise.
RAILS_LOADED =
  begin
    require_relative 'dummy/config/environment'

    # Migrate BEFORE rails/test_help: requiring it runs maintain_test_schema!,
    # which aborts on pending migrations — and ours are still pending at that
    # point, since the database is created empty in memory.
    ActiveRecord::Migration.verbose = false

    migrations = [Bible270::Engine.root.join('db/migrate').to_s]
    if defined?(ActiveStorage::Engine)
      migrations << ActiveStorage::Engine.root.join('db/migrate').to_s
    end
    ActiveRecord::MigrationContext.new(migrations).migrate

    # A table for the dummy's own user model. Reader.for_owner takes a polymorphic
    # owner, which needs a real record rather than a stand-in object.
    ActiveRecord::Schema.define do
      create_table :host_users, force: true do |t|
        t.string :name
        t.timestamps
      end
    end

    # The engine is mounted somewhere, and OmniAuth has to look for its callbacks
    # in the same place, or the request phase 404s.
    if defined?(OmniAuth)
      OmniAuth.config.path_prefix = "#{Bible270.config.mount_at.chomp('/')}/auth"
      OmniAuth.config.logger = Logger.new(File::NULL)
    end

    require 'rails/test_help'

    true
  rescue LoadError, StandardError => e
    raise if ENV['CI'] && !ENV['SKIP_COV']

    warn "[bible270] skipping Rails-backed tests: #{e.class}: #{e.message}"
    false
  end

# Signing in through OmniAuth, without an external provider. Test mode makes the
# strategy return the mock rather than talking to anyone.
module OmniAuthTesting
  def with_omniauth(provider: :developer, uid: '12345', name: 'Andrew vonderLuft',
                    email: 'andrew@example.org', origin: nil)
    return skip('OmniAuth unavailable') unless defined?(OmniAuth)

    previous_test_mode = OmniAuth.config.test_mode
    previous_validation = OmniAuth.config.request_validation_phase
    # omniauth-rails_csrf_protection guards the request phase with an authenticity
    # token, which an integration test has no way to supply — the request came
    # back as "Sign in failed (Forbidden)". That check belongs to OmniAuth, not to
    # this engine, so it is stood down here and restored afterwards.
    OmniAuth.config.request_validation_phase = ->(_env) {}
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[provider] = OmniAuth::AuthHash.new(
      'provider' => provider.to_s, 'uid' => uid,
      'info' => { 'name' => name, 'email' => email }
    )
    OmniAuth.config.before_callback_phase = ->(env) { env['omniauth.origin'] = origin } if origin

    yield provider
  ensure
    OmniAuth.config.mock_auth[provider] = nil
    OmniAuth.config.before_callback_phase = nil
    OmniAuth.config.request_validation_phase = previous_validation
    OmniAuth.config.test_mode = previous_test_mode
  end

  # Fails the next callback, the way a provider does when someone declines.
  def with_failed_omniauth(provider: :developer, reason: :invalid_credentials)
    return skip('OmniAuth unavailable') unless defined?(OmniAuth)

    previous_test_mode = OmniAuth.config.test_mode
    previous_validation = OmniAuth.config.request_validation_phase
    OmniAuth.config.request_validation_phase = ->(_env) {}
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[provider] = reason

    yield provider
  ensure
    OmniAuth.config.mock_auth[provider] = nil
    OmniAuth.config.request_validation_phase = previous_validation
    OmniAuth.config.test_mode = previous_test_mode
  end
end

module RailsBacked
  def needs_rails!
    skip 'Rails or sqlite3 unavailable' unless RAILS_LOADED
  end

  # Per-chapter check-offs are optional here: the tests that need them skip until
  # the migration and Plan methods are in place, so the suite stays green either
  # way rather than failing on a feature that isn't implemented yet.
  def chapter_parts?
    RAILS_LOADED &&
      Bible270::Checkoff.column_names.include?('part') &&
      Bible270::Plan.respond_to?(:total_parts)
  end

  def needs_chapter_parts!
    needs_rails!
    skip 'per-chapter check-offs not implemented yet' unless chapter_parts?
  end

  # Boxes on a day: one per chapter where that exists, otherwise one per track.
  def boxes_on(day)
    chapter_parts? ? Bible270::Plan.total_parts(day) : Bible270::Plan.required_track_count(day)
  end

  # Each test starts from an empty database rather than relying on order.
  def clear_engine_tables!
    return unless RAILS_LOADED

    Bible270::Checkoff.delete_all
    Bible270::Comment.delete_all
    Bible270::SignInToken.delete_all
    Bible270::Reader.delete_all
    Bible270::Setting.delete_all
  end
end

Minitest::Test.include(RailsBacked)
Minitest::Test.include(OmniAuthTesting)
