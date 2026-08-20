# frozen_string_literal: true

module Bible270
  class ReadersController < ApplicationController
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
      # An empty relation rather than nil, so the view needs no safe navigation.
      @recent_comments = @reader ? @reader.comments.recent.limit(5) : Comment.none
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

    def restart_schedule
      return unless require_reader!

      unless Bible270.config.allow_reader_start_date
        redirect_to progress_path, alert: 'The start date is set for the whole community.' and return
      end

      next_day = current_reader.current_day
      today = current_reader.today_day
      unless today && next_day < today
        redirect_to progress_path, notice: 'Your reading schedule is already up to date.' and return
      end

      current_reader.restart_on!(day: next_day)
      redirect_to progress_path,
                  notice: "Day #{next_day} is now today. All your reading progress is unchanged."
    end
  end
end
