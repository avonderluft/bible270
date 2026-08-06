# frozen_string_literal: true

Rails.application.configure do
  config.eager_load = false

  # The engine's migrations are run by hand into an in-memory database in
  # test_helper, so there is no schema for Rails to check against.
  config.active_record.maintain_test_schema = false
  config.consider_all_requests_local = true
  config.action_controller.allow_forgery_protection = false
  config.action_mailer.delivery_method = :test
  config.active_support.deprecation = :stderr

  # :rescuable, not :none. An unexpected exception in an action must reach the
  # test with its backtrace rather than arriving as "expected 2XX, got 500" —
  # but the admin panel hides itself by raising RoutingError on purpose, and that
  # has to keep turning into a 404 response. :rescuable renders the exceptions
  # Rails maps to statuses and raises everything else.
  config.action_dispatch.show_exceptions = :rescuable

  # And keep a log, so anything that does get swallowed is still recoverable.
  # The application config sends logs to /dev/null to keep test output clean;
  # a file gives us both.
  config.logger = ActiveSupport::Logger.new(Rails.root.join('log/test.log'))
  config.log_level = :debug
end
