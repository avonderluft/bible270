# frozen_string_literal: true

module Bible270
  class ApplicationController < Bible270.config.parent_controller.constantize
    # Rails only auto-includes an isolated engine's helpers when the controller's
    # superclass is *exactly* ActionController::Base:
    #
    #   # ActionController::Railties::Helpers#inherited
    #   klass.helpers_path = namespace.railtie_helpers_paths
    #   klass.helper :all if klass.superclass == ActionController::Base && ...
    #
    # config.parent_controller normally points at the host's ApplicationController,
    # so that check fails and the b270_* helpers are never mixed in — every view
    # calling one then raises NoMethodError. helpers_path is still set to this
    # engine's app/helpers, so asking for them explicitly is all that's needed.
    helper :all
    # ...and name it outright, in case helpers_path resolves to the host app's
    # helpers rather than this engine's.
    helper Bible270::PlanHelper

    layout :bible270_layout

    helper_method :current_reader, :signed_in?, :b270_config

  private

    def bible270_layout
      Bible270.config.layout
    end

    def b270_config
      Bible270.config
    end

    def current_reader
      return @current_reader if defined?(@current_reader)

      @current_reader =
        if (resolver = Bible270.config.current_reader_resolver)
          resolver.call(self)
        elsif (id = session[:bible270_reader_id])
          Reader.find_by(id: id)
        end
    end

    def signed_in?
      current_reader.present?
    end

    # Guard participation (checking off / commenting). Viewing is always open.
    def require_reader!
      return true if signed_in?
      return true unless Bible270.config.require_sign_in_to_participate

      respond_to do |format|
        format.turbo_stream { head :unauthorized }
        format.html do
          redirect_to sign_in_path(origin: request.fullpath),
                      alert: 'Please sign in to take part.'
        end
      end
      false
    end
  end
end
