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

    def create
      auth = request.env["omniauth.auth"]
      unless auth
        redirect_to(sign_in_path, alert: "Sign in didn't complete. Please try again.") and return
      end

      reader = Reader.from_omniauth(auth)
      unless reader&.persisted?
        redirect_to(sign_in_path, alert: "We couldn't set up your reader profile.") and return
      end

      destination = safe_origin(request.env["omniauth.origin"]) || after_sign_in_path

      # Rotate the session id to avoid session fixation, then sign in.
      reset_session
      session[:bible270_reader_id] = reader.id
      @current_reader = reader

      redirect_to destination, notice: "Welcome, #{reader.display_name}."
    end

    def destroy
      reset_session
      @current_reader = nil
      redirect_to(after_sign_out_path, notice: "Signed out.")
    end

    def failure
      message = params[:message].presence || "unknown error"
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

      name = Bible270.config.email_sign_in_ask_name ? params[:display_name].to_s.strip : nil
      _record, raw = SignInToken.issue!(address, display_name: name)

      if raw
        url = email_sign_in_url(token: raw, origin: origin)
        minutes = (Bible270.config.email_sign_in_ttl / 60.0).round
        mail = SignInMailer.magic_link(email: address, url: url, expires_in_minutes: minutes)
        Bible270.config.email_sign_in_deliver_later ? mail.deliver_later : mail.deliver_now
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
                    alert: "That link has expired or was already used. Please request a new one.") and return
      end

      reader = Reader.from_email(token.email, display_name: token.display_name)
      unless reader&.persisted?
        redirect_to(sign_in_path, alert: "We couldn't set up your reader profile.") and return
      end

      destination = safe_origin(params[:origin]) || after_sign_in_path

      reset_session
      session[:bible270_reader_id] = reader.id
      @current_reader = reader

      redirect_to destination, notice: "Welcome, #{reader.display_name}."
    end

    private

    # Only ever redirect within this app, and never back into an auth route.
    def safe_origin(value)
      value = value.to_s
      return nil if value.empty?
      return nil unless value.start_with?("/")
      return nil if value.include?("//")   # protocol-relative URL
      return nil if value.include?("\\")   # browsers may normalise \ to /
      return nil if value.include?("/auth/")

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
