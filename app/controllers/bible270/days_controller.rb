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
      redirect_to(root_path, alert: 'That day is outside the plan.') and return unless Plan.valid_day?(@day)

      @readings   = Plan.readings_for(@day)
      @comments   = Comment.threads_for_day(@day)
      @editing_comment_id = editing_comment_id
      @new_comment = Comment.new(day: @day, parent_id: reply_parent&.id)
      @reader_tracks = current_reader ? current_reader.read_tracks_for(@day) : []
      @day_just_completed = flash[:b270_day_just_completed].to_i == @day
      @completion_event_id = flash[:b270_completion_event_id] if @day_just_completed

      # Every box on the day, not every track: an Old Testament reading of three
      # chapters is three rows, so counting tracks would call someone finished
      # who had only read the Old Testament.
      required = Plan.total_parts(@day)
      completer_ids = Checkoff.where(day: @day)
        .group(:reader_id)
        .having('COUNT(*) >= ?', required)
        .pluck(:reader_id)
      @completers = Reader.where(id: completer_ids).order(:display_name)
    end

  private

    # The reflection the reader has asked to edit: their own, on this day. Anything
    # else is ignored rather than refused — the page still renders.
    def editing_comment_id
      return nil if params[:edit].blank? || current_reader.nil?

      current_reader.comments.where(day: @day, id: params[:edit]).pick(:id)
    end

    # The reflection being replied to, if the link carried one and it is a
    # top-level reflection: a reply to a reply is not allowed.
    def reply_parent
      parent = Comment.approved.find_by(id: params[:reply_to])
      parent if parent && parent.day == @day && parent.parent_id.nil?
    end
  end
end
