# frozen_string_literal: true

module Bible270
  # Small administrative panel: remove readers, adjust their completions, and
  # move them to a given day of the plan.
  #
  # Access is controlled by Bible270.config.admin_emails / admin_resolver. With
  # neither set the panel is unreachable, and every action 404s rather than 403s
  # so its existence isn't advertised.
  class AdminController < ApplicationController
    before_action :require_admin!
    before_action :load_reader,
                  only: %i[show destroy update_start update_name complete_through toggle_day]
    before_action :load_comment, only: %i[hide_comment unhide_comment destroy_comment]

    def index
      @readers = Reader.all.to_a.sort_by(&:sort_name)
      counts = Checkoff.group(:reader_id, :day).count
      @days_completed = Hash.new(0)
      counts.each { |(rid, day), n| @days_completed[rid] += 1 if n >= Plan.required_track_count(day) }
    end

    def show
      @days_completed = @reader.days_completed
      @comments = @reader.comments.order(created_at: :desc).limit(50)
    end

    # ---- reflections ------------------------------------------------------

    # Everything is visible by default; this lists it all so anything unsuitable
    # can be taken down.
    def comments
      scope = Comment.includes(:reader).order(created_at: :desc)
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

    def update_name
      if @reader.update_names(params[:first_name], params[:last_name])
        redirect_to admin_reader_path(@reader), notice: 'Name updated.'
      else
        redirect_to admin_reader_path(@reader), alert: 'Both a first and last name are needed.'
      end
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
