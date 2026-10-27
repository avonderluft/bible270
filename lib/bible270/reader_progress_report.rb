# frozen_string_literal: true

module Bible270
  # Builds the plain-text reader progress table used by administrative tasks.
  class ReaderProgressReport
    HEADERS = ['Name', 'Days Read', 'Status', 'Last Activity'].freeze
    SORTS = %w[
      first_name last_name most_completed least_completed most_recent_activity least_recent_activity consistency
    ].freeze
    DEFAULT_SORT = 'most_completed'
    Row = Struct.new(:name, :days_read, :status, :last_activity, keyword_init: true)

    def initialize(readers: Reader.all, completed_days: Reader.completed_days_by_id, recent_activities: nil,
                   sort: DEFAULT_SORT)
      @readers = readers.to_a
      @completed_days = completed_days
      @recent_activities = recent_activities || Checkoff.recent_activity_by_reader(@readers.map(&:id))
      @sort = SORTS.include?(sort.to_s) ? sort.to_s : DEFAULT_SORT
    end

    def sorted_readers
      @sorted_readers ||= readers.to_a.sort_by { |reader| reader_sort_key(reader) }
    end

    def rows
      @rows ||= sorted_readers.map do |reader|
        days_read = completed_days.fetch(reader.id, 0)
        Row.new(
          name: reader.display_name,
          days_read: days_read,
          status: reader.progress_status(completed_days: days_read),
          last_activity: last_activity_date(reader)
        )
      end
    end

    def status_for(reader)
      reader.progress_status(completed_days: completed_days.fetch(reader.id, 0))
    end

    def consistency_for(reader)
      @consistency ||= ReaderConsistency.new(readers: readers)
      @consistency.for(reader)
    end

    def empty? = rows.empty?

    def to_table
      values = rows.map { |row| [row.name, row.days_read.to_s, row.status, row.last_activity] }
      headers = HEADERS
      if sort == 'consistency'
        headers = ['Rank', *HEADERS]
        ranks = consistency_ranks
        values.each_with_index { |value, index| value.unshift(ranks[index]) }
      end
      widths = headers.each_index.map do |index|
        ([headers[index].length] + values.map { |value| value[index].length }).max
      end
      format = headers.each_with_index.map do |header, index|
        alignment = ['Rank', 'Days Read'].include?(header) ? '' : '-'
        "%#{alignment}#{widths[index]}s"
      end.join('  ')
      lines = [format % headers, format % widths.map { |width| '-' * width }].map(&:rstrip)
      lines.concat(values.map { |value| (format % value).rstrip })
      lines.join("\n")
    end

  private

    attr_reader :readers, :completed_days, :recent_activities, :sort

    def consistency_ranks
      previous_key = nil
      rank = 0
      sorted_readers.each_with_index.map do |reader, index|
        result = consistency_for(reader)
        next '—' unless result.ranked?

        key = result.rank_key
        rank = index + 1 if key != previous_key
        previous_key = key
        rank.to_s
      end
    end

    def reader_sort_key(reader)
      case sort
      when 'first_name'
        [reader.sort_name, reader.id]
      when 'last_name'
        last_name = reader.last_name.presence || reader.display_name.to_s.split.last
        [last_name.to_s.downcase, reader.sort_name, reader.id]
      when 'least_completed'
        [completed_days[reader.id].to_i, reader.sort_name, reader.id]
      when 'consistency'
        consistency_for(reader).sort_key(reader)
      when 'most_recent_activity'
        activity_sort_key(reader, descending: true)
      when 'least_recent_activity'
        activity_sort_key(reader, descending: false)
      else
        [-completed_days[reader.id].to_i, reader.sort_name, reader.id]
      end
    end

    def activity_sort_key(reader, descending:)
      activity = recent_activities[reader.id]
      timestamp = activity&.occurred_at&.to_f
      [activity.nil? ? 1 : 0, descending && timestamp ? -timestamp : timestamp.to_f, reader.sort_name, reader.id]
    end

    def last_activity_date(reader)
      occurred_at = recent_activities[reader.id]&.occurred_at
      occurred_at ? Bible270.local_time(occurred_at).strftime('%b %-d, %Y') : '—'
    end
  end
end
