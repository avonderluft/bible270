# frozen_string_literal: true

module Bible270
  # Small administrative panel: remove readers, adjust their completions, and
  # move them to a given day of the plan.
  #
  # Access is controlled by Bible270.config.admin_emails / admin_resolver. With
  # neither set the panel is unreachable, and every action 404s rather than 403s
  # so its existence isn't advertised.
  class AdminController < ApplicationController
    LAST_BROADCAST_AT = 'last_broadcast_at'
    LAST_BROADCAST_SUBJECT = 'last_broadcast_subject'

    before_action :require_admin!
    before_action :load_reader,
                  only: %i[show destroy update_start update_profile remove_avatar complete_through toggle_day]
    before_action :load_comment, only: %i[hide_comment unhide_comment destroy_comment]

    # ---- enrolment --------------------------------------------------------

    def update_enrollment
      if params[:state] == 'closed'
        Setting.close_enrollment!
        redirect_to admin_path, notice: 'Closed to new readers. Existing readers can still sign in.'
      else
        Setting.open_enrollment!
        redirect_to admin_path, notice: 'Open to new readers.'
      end
    end

    def index
      @enrollment_closed = Setting.enrollment_closed?
      @enrollment_closed_at = Setting.enrollment_closed_at
      @readers = Reader.all.to_a.sort_by(&:sort_name)
      counts = Checkoff.group(:reader_id, :day).count
      @days_completed = Hash.new(0)
      counts.each { |(rid, day), n| @days_completed[rid] += 1 if n >= Plan.total_parts(day) }
      @reachable = Reader.where.not(email: [nil, '']).count
      @last_broadcast_at = parsed_time(Setting.read(LAST_BROADCAST_AT))
      @last_broadcast_subject = Setting.read(LAST_BROADCAST_SUBJECT)
    end

    def show
      @days_completed = @reader.days_completed
      @comments = @reader.comments.order(created_at: :desc).limit(50)
    end

    # ---- reflections ------------------------------------------------------

    # Everything is visible by default; this lists it all so anything unsuitable
    # can be taken down.
    def comments
      scope = Comment.includes(:reader, parent: :reader).order(created_at: :desc)
      @filter = params[:filter].to_s
      scope = scope.hidden if @filter == 'hidden'
      scope = scope.approved if @filter == 'visible'
      @comments = scope.limit(200)
      @hidden_count = Comment.hidden.count
    end

    def hide_comment
      @comment.hide!
      redirect_back_to_comments "Hidden #{@comment.reader.display_name}'s reflection on day #{@comment.day}."
    end

    def unhide_comment
      @comment.unhide!
      redirect_back_to_comments "Restored #{@comment.reader.display_name}'s reflection on day #{@comment.day}."
    end

    def destroy_comment
      day = @comment.day
      @comment.destroy
      redirect_back_to_comments "Deleted the reflection on day #{day}."
    end

    def destroy
      name = @reader.display_name
      @reader.destroy
      redirect_to admin_path, notice: "Removed #{name} and all their check-offs and reflections."
    end

    # Put the reader on a given day as of today, or set an explicit start date.
    def broadcast
      subject = params[:subject].to_s.strip
      body = params[:body].to_s.strip

      if subject.empty? || body.empty?
        return redirect_to(admin_path, alert: 'A message needs both a subject and something to say.')
      end

      recipients = Reader.where.not(email: [nil, '']).order(:id)
      return redirect_to(admin_path, alert: 'Nobody has an email address.') if recipients.empty?

      sent = deliver_broadcast(recipients, subject, body)
      Setting.write(LAST_BROADCAST_AT, Time.current.iso8601)
      Setting.write(LAST_BROADCAST_SUBJECT, subject)

      redirect_to admin_path,
                  notice: "Sent to #{sent} #{'reader'.pluralize(sent)}."
    end

    def update_bible_version
      reader = Reader.find_by(id: params[:id])
      return redirect_to(admin_path, alert: 'No such reader.') if reader.nil?

      code = params[:bible_version].to_s
      # Blank means "no preference": the reader follows the site default, which is
      # not the same as choosing whichever translation the site happens to use now.
      if code.empty?
        reader.update(bible_version: nil)
        return redirect_to admin_reader_path(reader),
                           notice: "#{reader.display_name} now follows the site default " \
                                   "(#{Bible270.config.bible_version})."
      end

      if reader.update_bible_version(code)
        redirect_to admin_reader_path(reader),
                    notice: "#{reader.display_name} now reads the #{reader.bible_version_label}."
      else
        redirect_to admin_reader_path(reader), alert: 'That is not a translation on the list.'
      end
    end

    def update_start
      if params[:start_date].present?
        # set_start_date!, not update_start_date!: an admin is not subject to
        # config.allow_reader_start_date, which governs what readers may do to
        # their own dates.
        if @reader.set_start_date!(params[:start_date])
          redirect_to admin_reader_path(@reader),
                      notice: "Start date set to #{@reader.started_on.strftime('%B %-d, %Y')}."
        else
          redirect_to admin_reader_path(@reader),
                      alert: "Couldn't read #{params[:start_date].inspect} as a date."
        end
      elsif params[:day].present? && @reader.restart_on!(day: params[:day])
        redirect_to admin_reader_path(@reader),
                    notice: "#{@reader.display_name} is now on day #{params[:day]}."
      else
        redirect_to admin_reader_path(@reader), alert: 'Give a start date or a day between 1 and 270.'
      end
    end

    # Name and picture together, mirroring what a reader can change about
    # themselves on their own profile.
    def update_profile
      problems = []
      if (params[:first_name].present? || params[:last_name].present?) && !@reader.update_names(params[:first_name],
                                                                                                params[:last_name])
        problems << 'both a first and last name'
      end
      if params[:avatar].present? && !@reader.attach_avatar(params[:avatar])
        problems << (@reader.errors[:avatar].first || 'a valid image')
      end

      if problems.empty?
        redirect_to admin_reader_path(@reader), notice: 'Updated.'
      else
        redirect_to admin_reader_path(@reader), alert: "Needs #{problems.to_sentence}."
      end
    end

    def remove_avatar
      @reader.remove_avatar!
      redirect_to admin_reader_path(@reader), notice: "Removed #{@reader.display_name}'s picture."
    end

    def complete_through
      day = params[:day].to_i
      if @reader.mark_through!(day)
        redirect_to admin_reader_path(@reader),
                    notice: day.zero? ? 'All check-offs cleared.' : "Marked days 1-#{day} complete."
      else
        redirect_to admin_reader_path(@reader), alert: 'Give a day between 0 and 270.'
      end
    end

    def toggle_day
      day = params[:day].to_i
      if @reader.toggle_day!(day)
        redirect_to admin_reader_path(@reader, anchor: "day-#{day}")
      else
        redirect_to admin_reader_path(@reader), alert: 'That day is outside the plan.'
      end
    end

    # Failures are counted rather than raised: one bad address must not stop the
    # rest of the message going out, and the admin is told how many were sent.
    # A stored timestamp that cannot be read is treated as absent rather than
    # blowing up the admin page.
    def parsed_time(value)
      return nil if value.blank?

      Time.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def deliver_broadcast(recipients, subject, body)
      later = Bible270.config.registration_notice_deliver_later
      sent = 0

      recipients.find_each do |reader|
        mail = NoticeMailer.broadcast(reader_id: reader.id, subject: subject, body: body)
        later ? mail.deliver_later : mail.deliver_now
        sent += 1
      rescue StandardError => e
        Rails.logger.error("[bible270] broadcast to reader #{reader.id} failed: #{e.class}: #{e.message}")
      end

      sent
    end

  private

    def require_admin!
      return if Bible270.config.admin_configured? && Bible270.config.admin?(current_reader)

      raise ActionController::RoutingError, 'Not Found'
    end

    def load_comment
      @comment = Comment.find_by(id: params[:id])
      redirect_to(admin_comments_path, alert: 'Reflection not found.') if @comment.nil?
    end

    def redirect_back_to_comments(notice)
      redirect_to(params[:return_to].presence || admin_comments_path, notice: notice)
    end

    def load_reader
      @reader = Reader.find_by(id: params[:id])
      redirect_to(admin_path, alert: 'Reader not found.') if @reader.nil?
    end
  end
end
