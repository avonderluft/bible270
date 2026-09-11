# frozen_string_literal: true

module Bible270
  # Builds the plain-text reader progress table used by administrative tasks.
  class ReaderProgressReport
    HEADERS = ['Name', 'Days Read', 'Status'].freeze
    Row = Struct.new(:name, :days_read, :status, keyword_init: true)

    def initialize(readers: Reader.all, completed_days: Reader.completed_days_by_id)
      @readers = readers
      @completed_days = completed_days
    end

    def rows
      @rows ||= begin
        report_rows = readers.map do |reader|
          days_read = completed_days.fetch(reader.id, 0)
          Row.new(name: reader.display_name, days_read: days_read, status: status(reader, days_read))
        end
        report_rows.sort_by { |row| [-row.days_read, row.name.downcase, row.name] }
      end
    end

    def empty? = rows.empty?

    def to_table
      values = rows.map { |row| [row.name, row.days_read.to_s, row.status] }
      widths = HEADERS.each_index.map do |index|
        ([HEADERS[index].length] + values.map { |value| value[index].length }).max
      end
      format = "%-#{widths[0]}s  %#{widths[1]}s  %-#{widths[2]}s"
      lines = [format % HEADERS, format % widths.map { |width| '-' * width }].map(&:rstrip)
      lines.concat(values.map { |value| (format % value).rstrip })
      lines.join("\n")
    end

  private

    attr_reader :readers, :completed_days

    def status(reader, days_read)
      calendar_day = reader.calendar_day
      return 'undated' unless calendar_day

      difference = days_read - calendar_day
      return 'on track' if difference.zero?

      amount = difference.abs
      "#{amount} #{amount == 1 ? 'day' : 'days'} #{difference.positive? ? 'ahead' : 'behind'}"
    end
  end
end
