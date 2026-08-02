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
end
