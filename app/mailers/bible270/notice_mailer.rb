# frozen_string_literal: true

module Bible270
  # Notices to whoever runs the plan, as opposed to mail sent to readers.
  class NoticeMailer < ApplicationMailer
    def new_reader(reader_id:, recipients:)
      @reader = Reader.find_by(id: reader_id)
      return message.perform_deliveries = false if @reader.nil? || recipients.blank?

      @app_name = Bible270.config.app_name
      @total = Reader.count
      @admin_url = admin_url_for(@reader)

      mail to: recipients, subject: "#{@app_name}: #{@reader.display_name} has joined"
    end

  private

    # A mailer has no request, so the host is config.mailer_host or nothing. No
    # link is better than a broken one.
    def admin_url_for(reader)
      host = Bible270.config.mailer_host
      return nil if host.blank?

      Bible270::Engine.routes.url_helpers.admin_reader_url(
        reader, host: host, protocol: host.start_with?('localhost') ? 'http' : 'https'
      )
    rescue StandardError
      nil
    end
  end
end
