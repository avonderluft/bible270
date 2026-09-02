# frozen_string_literal: true

module Bible270
  class ApplicationController < Bible270.config.parent_controller.constantize
    # The long-lived sign-in cookie. private_constant rather than sitting below
    # `private`, which does not apply to constants — rubocop is right that the
    # placement said something it could not do.
    REMEMBER_COOKIE = :bible270_remember
    private_constant :REMEMBER_COOKIE

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

    rescue_from ActionController::InvalidAuthenticityToken, with: :recover_from_stale_page

    helper_method :current_reader, :signed_in?, :b270_config, :enrollment_closed?

  private

    def bible270_layout
      Bible270.config.layout
    end

    def enrollment_closed?
      Setting.enrollment_closed?
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
        else
          reader_from_remember_cookie
        end
    end

    # A session cookie dies when the browser restarts, which on a phone can be
    # daily. This restores the session from a long-lived signed cookie carrying
    # the reader id and a rotating token, so the reader stays signed in.
    def reader_from_remember_cookie
      return nil unless Bible270.config.remember_signed_in?

      payload = cookies.encrypted[REMEMBER_COOKIE]
      return nil if payload.blank?

      id, token = payload.to_s.split(':', 2)
      reader = Reader.from_remember_cookie(id, token)
      return forget_reader! if reader.nil?

      # Re-establish the session so the rest of the request behaves as normal.
      session[:bible270_reader_id] = reader.id
      reader
    rescue StandardError => e
      # A cookie is attacker-supplied input: a damaged or forged one must sign
      # nobody in, and must never take the site down. Anything unexpected here is
      # treated as "not remembered", and the cookie is dropped.
      Rails.logger.warn("[bible270] ignoring an unusable remember cookie: #{e.class}: #{e.message}")
      forget_reader!
    end

    # Encrypted, so the payload can be neither read nor forged by the client.
    def remember_reader!(reader)
      return unless Bible270.config.remember_signed_in?

      cookies.encrypted[REMEMBER_COOKIE] = {
        value: "#{reader.id}:#{reader.remember_token!}",
        expires: Bible270.config.remember_for.to_i.seconds.from_now,
        httponly: true,
        same_site: :lax,
        secure: request.ssl?
      }
    end

    def forget_reader!
      cookies.delete(REMEMBER_COOKIE)
      nil
    end

    def signed_in?
      current_reader.present?
    end

    # A suspended mobile tab can outlive its Rails session cookie. The page still
    # contains the old session's CSRF token, so Rails would normally raise before
    # current_reader could restore the session from the remember cookie. Redirect
    # directly from Rails' forgery callback; rescue_from remains a fallback for an
    # authenticity exception raised anywhere else in the request.
    def handle_unverified_request
      recover_from_stale_page
    end

    def recover_from_stale_page(error = nil)
      reason = error ? error.class : 'an unverified request'
      Rails.logger.info("[bible270] silently refreshing a page after #{reason}")

      if request.format.turbo_stream?
        response.set_header('X-Bible270-Refresh-Session', 'true')
        response.set_header('Cache-Control', 'no-store')
        head :conflict
      else
        redirect_back fallback_location: root_path, allow_other_host: false, status: :see_other
      end
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
