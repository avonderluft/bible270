# frozen_string_literal: true

module Bible270
  # Notices to whoever runs the plan, as opposed to mail sent to readers.
  class NoticeMailer < ApplicationMailer
    def new_reader(reader_id:, recipients:)
      @reader = Reader.find_by(id: reader_id)
      # Blanks dropped rather than trusting the caller: ['']  is not blank — a
      # one-element array never is — so it would otherwise have been sent to an
      # empty address, which fails at the SMTP server rather than here.
      addresses = Array(recipients).map { |address| address.to_s.strip }.reject(&:empty?)
      return message.perform_deliveries = false if @reader.nil? || addresses.empty?

      @app_name = Bible270.config.app_name
      @total = Reader.count
      @admin_url = admin_url_for(@reader)

      mail to: addresses, subject: "#{@app_name}: #{@reader.display_name} has joined"
    end

    def mentioned(comment_id:, reader_id:)
      @comment = Comment.find_by(id: comment_id)
      @reader = Reader.find_by(id: reader_id)
      return message.perform_deliveries = false if @comment.nil? || @reader.nil? || @reader.email.blank?

      @author = @comment.reader
      @app_name = Bible270.config.app_name
      @day_url = day_url_for(@comment.day)

      mail to: @reader.email,
           subject: "#{@app_name}: #{@author.display_name} mentioned you on day #{@comment.day}"
    end

  private

    # A mailer has no request, so the host is config.mailer_host or nothing. No
    # link is better than a broken one.
    def day_url_for(day)
      host = Bible270.config.mailer_host
      return nil if host.blank?

      Bible270::Engine.routes.url_helpers.day_url(
        day, host: host, protocol: host.start_with?('localhost') ? 'http' : 'https'
      )
    rescue StandardError
      nil
    end

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
