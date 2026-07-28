# frozen_string_literal: true

module Bible270
  class SignInMailer < ApplicationMailer
    # The URL is built by the controller (which has the request context), so the
    # mailer needs no default_url_options of its own.
    def magic_link(email:, url:, expires_in_minutes:)
      @url = url
      @expires_in_minutes = expires_in_minutes
      @app_name = Bible270.config.app_name

      mail to: email, subject: "Your sign-in link for #{@app_name}"
    end
  end
end
