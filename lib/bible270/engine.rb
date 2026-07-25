# frozen_string_literal: true
module Bible270
  class Engine < ::Rails::Engine
    isolate_namespace Bible270

    config.generators do |g|
      g.test_framework :minitest
      g.orm :active_record
    end

    # NOTE: we deliberately do NOT append the engine's db/migrate to the host
    # app's migration paths. Rails already gives mountable engines the task
    #
    #   bin/rails bible270:install:migrations
    #
    # which copies the migrations into the host's db/migrate, where the host
    # owns them and they appear in schema.rb normally. Doing both would define
    # each migration class twice and raise
    # ActiveRecord::DuplicateMigrationNameError.
  end
end
