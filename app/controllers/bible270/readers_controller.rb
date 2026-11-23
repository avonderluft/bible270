# frozen_string_literal: true

module Bible270
  class ReadersController < ApplicationController
    def index
      # Community is a directory of fellow readers, not a leaderboard. Keep the
      # order predictable without implying that progress determines standing.
      @readers = Reader.active.with_avatar.to_a.sort_by(&:sort_name)
      @today_day = current_reader&.today_day
      @show_admin_progress = b270_admin_view?
      return unless signed_in?

      @days_completed = Reader.completed_days_by_id
      @reader_today_days = community_today_days
      @completions = community_completions
    end

    # The reader's own progress. Deliberately open to visitors: the panel shows an
    # invitation to sign in rather than an error, and every value it needs comes
    # from the reader it is given.
    def progress
      @reader = current_reader
      # Defaults keep the open visitor page simple and make every view input explicit.
      @recent_comments = @reader ? recent_reflections(@reader, limit: 5) : []
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
      @recent_comments = recent_reflections(@reader, limit: 20)
    end

    def mention_suggestions
      return head :unauthorized unless signed_in?

      response.headers['Cache-Control'] = 'private, no-store'
      render json: { suggestions: Reader.mention_suggestions(params[:q], except: current_reader) }
    end

  private

    def community_completions
      finished, remaining = @readers.partition { |reader| @days_completed[reader.id] == reader.plan_days }
      lengths = finished.to_h { |reader| [reader.participation.id, reader.plan_days] }
      completions = completion_details(lengths)
      candidates = remaining.filter_map do |reader|
        reader.participation.id if reader.plan_days > Plan::DAYS && @days_completed[reader.id].to_i >= Plan::DAYS
      end
      return completions if candidates.empty?

      # Extra days can't substitute for missing days in the base plan.
      base_counts = Checkoff.completed_days_by_participation(candidates, through: Plan::DAYS)
      milestones = base_counts.select { |_id, count| count == Plan::DAYS }
      completions.merge(completion_details(milestones, through: Plan::DAYS))
    end

    def completion_details(lengths, through: nil)
      Checkoff.latest_checkoff_at_by_participation(lengths.keys, through: through).to_h do |id, at|
        [id, [lengths.fetch(id), Bible270.local_time(at)&.to_date]]
      end
    end

    def community_today_days
      # Resolve the shared schedule once, not with a settings query for every reader.
      shared_start = Setting.run_start_date
      today = Bible270.today
      @readers.to_h do |reader|
        start = (Bible270.config.allow_reader_start_date && reader.participation.started_on) || shared_start
        days = reader.plan_days
        day = Plan.day_for(today, start, clamp: false, days: days)
        [reader.id, Plan.valid_day?(day, days: days) ? day : nil]
      end
    end

    def recent_reflections(reader, limit:)
      comments = reader.comments.recent.with_thread_details.limit(limit).to_a
      ids = comments.map(&:id)
      # A reader's own replies already appear beneath any listed parent reflection.
      comments.reject { |comment| ids.include?(comment.parent_id) }
    end
  end
end
