# frozen_string_literal: true

module Bible270
  class ReadersController < ApplicationController
    def index
      # Community is a directory of fellow readers, not a leaderboard. Keep the
      # order predictable without implying that progress determines standing.
      @readers = Reader.all.to_a.sort_by(&:sort_name)
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
      return unless @reader

      partial_days = @reader.partial_days
      @partial_day_tasks = partial_days.first(5).map do |day|
        { day: day, remaining: @reader.remaining_parts_for(day) }
      end
      @remaining_partial_days = [partial_days.size - @partial_day_tasks.size, 0].max
    end

    def show
      @reader = Reader.find_by(id: params[:id])
      redirect_to(community_path, alert: 'Reader not found.') and return unless @reader

      @days_completed = @reader.days_completed
      @recent_comments = @reader.comments.recent.limit(20)
    end
  end
end
