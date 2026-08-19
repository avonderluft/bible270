# frozen_string_literal: true

module Bible270
  # Transactional mail for readers and notices for whoever runs the plan.
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

    def daily_reminder(reader_id:, day:, on: Bible270.today)
      @reader = Reader.find_by(id: reader_id)
      return message.perform_deliveries = false unless Bible270.config.daily_reminders?
      return message.perform_deliveries = false if @reader.nil? || !@reader.daily_reminders? || @reader.email.blank?

      @day = day.to_i
      @on = Plan.to_date(on)
      return message.perform_deliveries = false unless Plan.valid_day?(@day) && @on

      @readings = Plan.readings_for(@day).select { |_, reference| reference }
      @app_name = Bible270.config.app_name
      @day_url = day_url_for(@day)
      @profile_url = profile_url

      mail to: @reader.email, subject: "#{@app_name}: day #{@day} reading reminder"
    end

    # A message from whoever runs the plan to one reader. Sent individually rather
    # than as one email with everyone in bcc: a bcc list of a hundred addresses is
    # a spam signal, and it means nobody can be greeted by name or unsubscribe
    # meaningfully.
    def broadcast(reader_id:, subject:, body:)
      @reader = Reader.find_by(id: reader_id)
      return message.perform_deliveries = false if @reader.nil? || @reader.email.blank?
      return message.perform_deliveries = false if subject.to_s.strip.empty? || body.to_s.strip.empty?

      @body = body.to_s
      @app_name = Bible270.config.app_name
      @plan_url = plan_url

      mail to: @reader.email, subject: subject.to_s.strip
    end

  private

    # A mailer has no request, so the host is config.mailer_host or nothing. No
    # link is better than a broken one.
    #
    # The mount prefix needs no help: a mounted engine's url_helpers already
    # resolve it from the real mount point in routes.rb. Passing script_name from
    # config.mount_at was worse than useless — ignored when blank, and overriding
    # the true prefix when not, so a config that disagreed with routes.rb would
    # have produced links to nowhere.
    def plan_url
      engine_url(:root_url)
    end

    def day_url_for(day)
      engine_url(:day_url, day)
    end

    def admin_url_for(reader)
      engine_url(:admin_reader_url, reader)
    end

    def profile_url
      engine_url(:profile_url)
    end

    def engine_url(helper, *)
      host = Bible270.config.mailer_host
      return nil if host.blank?

      Bible270::Engine.routes.url_helpers.public_send(
        helper, *,
        host: host,
        protocol: host.start_with?('localhost') ? 'http' : 'https'
      )
    rescue StandardError
      nil
    end
  end
end
