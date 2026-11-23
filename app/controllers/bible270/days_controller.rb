# frozen_string_literal: true

module Bible270
  class DaysController < ApplicationController
    def index
      @plan_totals = Plan.totals

      @start_day = current_reader&.current_day || 1
      # nil outside the plan's window, so no "Go to today" before it begins
      @today_day = current_reader&.today_day
      @community_start_date = Setting.run_start_date
    end

    def show
      @day = params[:day].to_i
      @comments = Comment.threads_for_day(@day) if Plan.valid_day?(@day, days: Plan::EXTENDED_DAYS)
      @discussion_only = !Plan.valid_day?(@day, days: b270_plan_days)
      # Keep reflection links usable without opening this day for reading progress.
      if @discussion_only && @comments.blank?
        redirect_to root_path, alert: 'That day is outside the plan.'
        return
      end

      @editing_comment_id = editing_comment_id
      parent = reply_parent
      @new_comment = Comment.new_for_composer(day: @day, parent_id: parent&.id) if !@discussion_only || parent
      return if @discussion_only

      @readings = Plan.readings_for(@day)
      @reader_tracks = current_reader ? current_reader.read_tracks_for(@day) : []
      @day_just_completed = flash[:b270_day_just_completed].to_i == @day
      @completion_event_id = flash[:b270_completion_event_id] if @day_just_completed

      @completers = Reader.completers_for(@day)
    end

  private

    # The reflection the reader has asked to edit: their own, or any reflection
    # when they are an administrator. Anything else is ignored rather than refused.
    def editing_comment_id
      return nil if params[:edit].blank? || current_reader.nil?

      comments = b270_admin_view? ? Comment.all : current_reader.comments
      comments.where(day: @day, id: params[:edit]).pick(:id)
    end

    # The reflection being replied to, if the link carried one and it is a
    # top-level reflection: a reply to a reply is not allowed.
    def reply_parent
      return if params[:reply_to].blank?

      Comment.for_day(@day).find_by(id: params[:reply_to])
    end
  end
end
