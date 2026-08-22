# frozen_string_literal: true

module Bible270
  class ReadersController < ApplicationController
    MILESTONES = {
      30 => '30-day milestone',
      90 => 'one-third complete',
      135 => 'halfway',
      180 => 'two-thirds complete',
      Plan::DAYS => 'plan complete'
    }.freeze

    def index
      @readers = Reader.all.to_a
      counts = Checkoff.group(:reader_id, :day).count
      @days_completed = Hash.new(0)
      counts.each { |(rid, day), n| @days_completed[rid] += 1 if n >= Plan.total_parts(day) }
      # Community is a directory of fellow readers, not a leaderboard. Keep the
      # order predictable without implying that progress determines standing.
      @readers.sort_by!(&:sort_name)
    end

    # The reader's own progress. Deliberately open to visitors: the panel shows an
    # invitation to sign in rather than an error, and every value it needs comes
    # from the reader it is given.
    def progress
      @reader = current_reader
      # Defaults keep the open visitor page simple and make every view input explicit.
      @recent_comments = @reader ? @reader.comments.recent.limit(5) : Comment.none
      @partial_day_tasks = []
      @remaining_partial_days = 0
      @week_days = []
      @week_completed = 0
      @next_milestone = nil
      @days_to_milestone = nil
      return unless @reader

      partial_days = @reader.partial_days
      @partial_day_tasks = partial_days.first(5).map do |day|
        { day: day, remaining: @reader.remaining_parts_for(day) }
      end
      @remaining_partial_days = [partial_days.size - @partial_day_tasks.size, 0].max
      @week_days = @reader.scheduled_days_this_week
      @week_completed = @week_days.count { |day| @reader.day_complete?(day) }
      completed = @reader.days_completed
      @next_milestone = MILESTONES.find { |day, _label| day > completed }
      @days_to_milestone = @next_milestone&.first.to_i - completed if @next_milestone
    end

    def show
      @reader = Reader.find_by(id: params[:id])
      redirect_to(community_path, alert: 'Reader not found.') and return unless @reader

      @days_completed = @reader.days_completed
      @recent_comments = @reader.comments.recent.limit(20)
    end

    def update_start_date
      return unless require_reader!

      unless Bible270.config.allow_reader_start_date
        redirect_to(root_path, alert: 'The start date is set for the whole community.') and return
      end

      if current_reader.update_start_date!(params[:start_date])
        redirect_to root_path,
                    notice: "Start date set to #{current_reader.started_on.strftime('%B %-d, %Y')}."
      else
        redirect_to root_path, alert: "That doesn't look like a valid date."
      end
    end

    def clear_start_date
      return unless require_reader!

      if Bible270.config.allow_reader_start_date
        current_reader.clear_start_date!
        redirect_to root_path, notice: 'Start date cleared — the plan is now undated for you.'
      else
        redirect_to root_path, alert: 'The start date is set for the whole community.'
      end
    end
  end
end
