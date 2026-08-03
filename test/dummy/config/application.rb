# frozen_string_literal: true

require_relative 'boot'

# Only the frameworks the engine actually touches. A generated app pulls in far
# more, and every extra one is another thing that can break on a Rails version
# the CI matrix covers.
require 'rails'
require 'active_model/railtie'
require 'active_job/railtie'
require 'active_record/railtie'
require 'active_storage/engine'
require 'action_controller/railtie'
require 'action_view/railtie'
require 'action_mailer/railtie'

# The engine responds with turbo_stream and ships .turbo_stream.erb templates,
# so the dummy needs Turbo just as a real host app does.
require 'turbo-rails'

require 'bible270'

module Dummy
  class Application < Rails::Application
    # Never ask for defaults newer than the Rails under test.
    config.load_defaults [Rails::VERSION::STRING.to_f, 8.0].min

    config.root = File.expand_path('..', __dir__)
    config.eager_load = false
    config.secret_key_base = 'a' * 64
    config.hosts.clear

    config.active_storage.service = :test
    config.active_job.queue_adapter = :test
    config.action_mailer.delivery_method = :test
    config.action_mailer.default_url_options = { host: 'example.com' }

    # Keep the suite's output to test results.
    config.logger = ActiveSupport::Logger.new(File::NULL)
    config.log_level = :fatal
  end
end
