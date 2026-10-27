# frozen_string_literal: true

require 'bible270/plan'

module Bible270
  # Reconstructs completed evenings from surviving checkoffs and current start dates.
  class ReaderConsistency
    Result = Struct.new(:score, :on_track_percentage, :days_evaluated, keyword_init: true) do
      def ranked? = days_evaluated.positive?
      def provisional? = ranked? && days_evaluated < 7

      def rank_key
        group = if !ranked?
                  2
                elsif provisional?
                  1
                else
                  0
                end
        [group, -(score || 0), -(on_track_percentage || 0), -days_evaluated]
      end

      def sort_key(reader)
        [*rank_key, reader.sort_name, reader.id]
      end
    end

    def initialize(readers:, today: Bible270.today)
      readers = readers.to_a
      @today = today
      dates_by_reader = completion_dates(readers.map(&:id))
      @results = readers.to_h do |reader|
        [reader.id, evaluate(reader, dates_by_reader.fetch(reader.id, []))]
      end
    end

    def for(reader)
      @results.fetch(reader.id)
    end

  private

    def completion_dates(reader_ids)
      return {} if reader_ids.empty?

      checkoffs = Checkoff.where(reader_id: reader_ids, day: 1..Plan::DAYS).group(:reader_id, :day)
      counts = checkoffs.count
      latest = checkoffs.maximum(:created_at)
      dates = Hash.new { |hash, id| hash[id] = [] }
      counts.each do |(reader_id, day), count|
        next if count < Plan.total_parts(day)

        # A reader may clear a day between the count and timestamp queries.
        completed_at = latest[[reader_id, day]]
        dates[reader_id] << Bible270.local_time(completed_at).to_date if completed_at
      end
      dates.each_value(&:sort!)
      dates
    end

    def start_date_for(reader)
      return reader.effective_start_date if reader.own_start_date?
      return @shared_start_date if defined?(@shared_start_date)

      # effective_start_date reads the shared Setting; do that only once per collection.
      @shared_start_date = reader.effective_start_date
    end

    def evaluate(reader, dates)
      start_date = start_date_for(reader)
      unranked = Result.new(score: nil, on_track_percentage: nil, days_evaluated: 0)
      return unranked unless start_date

      first = [start_date, Bible270.local_time(reader.created_at).to_date].max
      last = [@today - 1, start_date + Plan::DAYS - 1].min
      return unranked if first > last

      completed = 0
      total_score = 0
      on_track = 0
      (first..last).each do |date|
        # Earlier completions carry into the window; later ones never improve its past evenings.
        completed += 1 while completed < dates.length && dates[completed] <= date
        balance = completed - (date - start_date).to_i - 1
        total_score += 100 + (5 * balance.clamp(0, 7)) - (10 * [-balance, 0].max)
        on_track += 1 if balance >= 0
      end
      days = (last - first).to_i + 1
      Result.new(score: Rational(total_score, days), on_track_percentage: Rational(100 * on_track, days),
                 days_evaluated: days)
    end
  end
end
