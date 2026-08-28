# frozen_string_literal: true

module Bible270
  # Built-in OmniAuth sign-in.
  #
  # The OmniAuth middleware (registered by the host app) handles the request and
  # callback phases; by the time #create runs, request.env["omniauth.auth"] is
  # populated and we just need to turn it into a Reader and remember them.
  #
  # NOTE: OmniAuth 2.0+ only permits POST to its request-phase routes, so all
  # sign-in controls in these views are forms/buttons rather than links.
  class SessionsController < ApplicationController
    def new
      redirect_to(after_sign_in_path, notice: "You're already signed in.") and return if signed_in?

      @providers = Bible270.config.omniauth_providers
      @origin = safe_origin(params[:origin])
    end

    # Refresh a resumed page's session and CSRF token without reloading its content.
    # Calling current_reader first lets the long-lived remember cookie rebuild a
    # browser session that the phone may have discarded while the tab was asleep.
    def refresh
      current_reader
      response.headers['X-CSRF-Token'] = form_authenticity_token
      response.headers['Cache-Control'] = 'no-store'
      head :no_content
    end

    def create
      auth = request.env['omniauth.auth']
      redirect_to(sign_in_path, alert: "Sign in didn't complete. Please try again.") and return unless auth

      if enrollment_closed? && !Reader.omniauth_reader_exists?(auth['provider'], auth['uid'])
        redirect_to(sign_in_path, alert: enrollment_closed_message) and return
      end

      reader = Reader.from_omniauth(auth)
      redirect_to(sign_in_path, alert: "We couldn't set up your reader profile.") and return unless reader&.persisted?

      destination = safe_origin(request.env['omniauth.origin']) || after_sign_in_path

      # Rotate the session id to avoid session fixation, then sign in.
      reset_session
      session[:bible270_reader_id] = reader.id
      remember_reader!(reader)
      @current_reader = reader

      # first_name is filled in for every route now, but a bridged host user may
      # still arrive without one.
      redirect_to destination, notice: "Welcome #{reader.first_name.presence || reader.display_name}."
    end

    def destroy
      # Clear the long-lived cookie too, or the next request would sign them
      # straight back in. The stored token is left alone so their other devices
      # stay signed in; Reader#forget! is what revokes those.
      forget_reader!
      reset_session
      @current_reader = nil
      redirect_to(after_sign_out_path, notice: 'Signed out.')
    end

    def failure
      message = params[:message].presence || 'unknown error'
      redirect_to sign_in_path, alert: "Sign in failed (#{message.to_s.tr('_', ' ')})."
    end

    # ---- email (magic link) sign-in ---------------------------------------

    # POST: accept an address and send a one-time link.
    def email_link
      unless Bible270.config.email_sign_in?
        redirect_to(sign_in_path, alert: "Email sign-in isn't enabled here.") and return
      end

      origin  = safe_origin(params[:origin])
      address = EmailSignIn.normalize_email(params[:email])
      if address.nil?
        redirect_to(sign_in_path(origin: origin),
                    alert: "That doesn't look like an email address — please check and try again.") and return
      end

      # Names are optional here. Requiring them only for unknown addresses would
      # make the response differ, which tells a stranger whether an address
      # already has an account. A new reader is asked for their name after they
      # click the link instead (see email_callback).
      names = Names.normalize(params[:first_name], params[:last_name])

      _record, raw = SignInToken.issue!(address, first_name: names&.dig(:first_name),
                                                 last_name: names&.dig(:last_name))

      if raw && enrollment_closed? && !Reader.email_reader_exists?(address)
        Rails.logger.info("[bible270] enrolment closed; no link sent to #{address}")
      elsif raw
        deliver_sign_in_link(address, email_sign_in_url(token: raw, origin: origin))
      else
        # Silent to the reader by design; say so in the log or this is undebuggable.
        Rails.logger.warn("[bible270] no sign-in link issued for #{address} " \
                          '(rate limited — see config.email_sign_in_max_per_window)')
      end

      # Deliberately identical whether or not a link was actually sent, so this
      # reveals neither who has an account nor that a limit was hit.
      redirect_to sign_in_path,
                  notice: "Check your inbox — if that address is valid we've sent a sign-in link to #{address}."
    end

    # GET: the reader clicked the link.
    def email_callback
      token = SignInToken.claim!(params[:token])
      if token.nil?
        redirect_to(sign_in_path,
                    alert: 'That link has expired or was already used. Please request a new one.') and return
      end

      if enrollment_closed? && !Reader.email_reader_exists?(token.email)
        redirect_to(sign_in_path, alert: enrollment_closed_message) and return
      end

      reader = Reader.from_email(token.email, first_name: token.first_name,
                                              last_name: token.last_name, display_name: token.display_name)
      redirect_to(sign_in_path, alert: "We couldn't set up your reader profile.") and return unless reader&.persisted?

      destination = safe_origin(params[:origin]) || after_sign_in_path

      reset_session
      session[:bible270_reader_id] = reader.id
      remember_reader!(reader)
      @current_reader = reader

      if name_needed?(reader)
        redirect_to(profile_path,
                    notice: 'Welcome. Please add your name, so others know who they are reading with.')
        return
      end

      redirect_to destination, notice: "Welcome #{reader.first_name}."
    end

  private

    # Delivery problems must not leak through the UI (the response is deliberately
    # identical either way), so they are logged rather than raised. Without this a
    # misconfigured mailer either 500s the request or fails silently, depending on
    # config.action_mailer.raise_delivery_errors.
    def deliver_sign_in_link(address, url)
      minutes = (Bible270.config.email_sign_in_ttl / 60.0).round
      mail = SignInMailer.magic_link(email: address, url: url, expires_in_minutes: minutes)
      Bible270.config.email_sign_in_deliver_later ? mail.deliver_later : mail.deliver_now
      Rails.logger.info("[bible270] sign-in email handed to Action Mailer for #{address}")
    rescue StandardError => e
      Rails.logger.error("[bible270] could not deliver the sign-in email to #{address}: #{e.class}: #{e.message}")
    ensure
      log_sign_in_link(address, url)
    end

    # In development and test, put the link in the log so you can sign in without
    # working mail delivery. Never in production — the link is a bearer token.
    def log_sign_in_link(address, url)
      return unless log_sign_in_link?

      Rails.logger.info("[bible270] sign-in link for #{address}: #{url}")
    end

    def log_sign_in_link?
      flag = Bible270.config.email_sign_in_log_link
      return flag unless flag.nil?

      Rails.env.development? || Rails.env.test?
    end

    # A reader who signed in by email and still has no first/last name. Applies
    # only to email sign-in: an OmniAuth reader carries whatever name their
    # provider gave.
    def name_needed?(reader)
      Bible270.config.email_sign_in_require_name &&
        reader.provider == 'email' &&
        reader.full_name.nil?
    end

    def enrollment_closed_message
      'This run of the plan is closed to new readers. If you have taken part before, ' \
        'sign in with the same email or account.'
    end

    # Only ever redirect within this app, and never back into an auth route.
    def safe_origin(value)
      value = value.to_s
      return nil if value.empty?
      return nil unless value.start_with?('/')
      return nil if value.include?('//')   # protocol-relative URL
      return nil if value.include?('\\')   # browsers may normalise \ to /
      return nil if value.include?('/auth/')
      # Never return someone to sign-in or sign-out after signing in: harmless,
      # but it reads as though the sign-in failed. Matched by path so it holds
      # wherever the engine is mounted.
      return nil if value.match?(%r{/sign_(in|out)(/|\z|\?)})

      value
    end

    def after_sign_in_path
      Bible270.config.after_sign_in_path || root_path
    end

    def after_sign_out_path
      Bible270.config.after_sign_out_path || root_path
    end
  end
end
