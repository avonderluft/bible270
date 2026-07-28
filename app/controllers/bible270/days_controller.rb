# frozen_string_literal: true

module Bible270
  class DaysController < ApplicationController
    def index
      @plan_totals = Plan.totals

      # Community leaderboard (small-community friendly; see README on scaling).
      @readers = Reader.order(updated_at: :desc).to_a
      counts = Checkoff.group(:reader_id, :day).count
      @days_completed = Hash.new(0)
      counts.each { |(rid, day), n| @days_completed[rid] += 1 if n >= Plan.required_track_count(day) }
      @readers = @readers.sort_by { |r| -@days_completed[r.id] }

      @start_day = current_reader&.current_day || 1
      @today_day = current_reader&.calendar_day
      @community_start_date = Bible270.config.start_date
      @allow_reader_start_date = Bible270.config.allow_reader_start_date
    end

    def show
      @day = params[:day].to_i
      redirect_to(root_path, alert: 'That day is outside the plan.') and return unless Plan.valid_day?(@day)

      @readings   = Plan.readings_for(@day)
      @comments   = Comment.for_day(@day).includes(:reader)
      @new_comment = Comment.new(day: @day)
      @reader_tracks = current_reader ? current_reader.read_tracks_for(@day) : []

      req = Plan.required_track_count(@day)
      completer_ids = Checkoff.where(day: @day)
        .group(:reader_id)
        .having('COUNT(*) >= ?', req)
        .pluck(:reader_id)
      @completers = Reader.where(id: completer_ids).order(:display_name)

      @prev_day = @day > 1 ? @day - 1 : nil
      @next_day = @day < Plan::DAYS ? @day + 1 : nil
    end
  end
end
