# frozen_string_literal: true

module Bible270
  class DaysController < ApplicationController
    def index
      @plan_totals = Plan.totals

      # Community leaderboard (small-community friendly; see README on scaling).
      @readers = Reader.order(updated_at: :desc).to_a
      counts = Checkoff.group(:reader_id, :day).count
      @days_completed = Hash.new(0)
      counts.each { |(rid, day), n| @days_completed[rid] += 1 if n >= Plan.total_parts(day) }
      @readers = @readers.sort_by { |r| -@days_completed[r.id] }

      @start_day = current_reader&.current_day || 1
      # nil outside the plan's window, so no "Go to today" before it begins
      @today_day = current_reader&.today_day
      @community_start_date = Bible270.config.start_date
      @allow_reader_start_date = Bible270.config.allow_reader_start_date
    end

    def show
      @day = params[:day].to_i
      redirect_to(root_path, alert: 'That day is outside the plan.') and return unless Plan.valid_day?(@day)

      @readings   = Plan.readings_for(@day)
      @comments   = Comment.threads_for_day(@day)
      # Replying prefills the form with the handle rather than needing JavaScript,
      # so it works with Turbo and without an asset pipeline.
      @editing_comment_id = editing_comment_id
      parent = reply_parent
      @new_comment = Comment.new(day: @day, parent_id: parent&.id, body: reply_prefix(parent))
      @reader_tracks = current_reader ? current_reader.read_tracks_for(@day) : []

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

    # "@handle " for the reflection being replied to, or nothing. Private, but
    # declared with the keyword rather than trailing the file, so it is obvious
    # this is not an action.
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

    # "@handle " so the author is mentioned — and so gets the email — without the
    # reader having to type it.
    def reply_prefix(parent)
      handle = parent&.reader&.mention_handle
      handle ? "@#{handle} " : nil
    end
  end
end
