# frozen_string_literal: true
module Bible270
  class Engine < ::Rails::Engine
    isolate_namespace Bible270

    config.generators do |g|
      g.test_framework :minitest
      g.orm :active_record
    end

    # Make the engine's migrations available to the host via
    #   bin/rails bible270:install:migrations
    initializer "bible270.append_migrations" do |app|
      unless app.root.to_s.match?(root.to_s)
        config.paths["db/migrate"].expanded.each do |path|
          app.config.paths["db/migrate"] << path
        end
      end
    end
  end
end
