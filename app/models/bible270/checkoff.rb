# frozen_string_literal: true

module Bible270
  # A single reader marking one track (ot / nt / pp) read on one day.
  class Checkoff < ApplicationRecord
    self.table_name = 'bible270_checkoffs'

    RecentActivity = Struct.new(:occurred_at, :day, :track, :part, :day_completed?, keyword_init: true)

    belongs_to :reader, class_name: 'Bible270::Reader'

    validates :day, inclusion: { in: 1..Plan::DAYS }
    validates :track, inclusion: { in: Plan::TRACKS.keys }
    validates :track, uniqueness: { scope: %i[reader_id day part] }
    validates :part, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate  :track_present_on_day
    validate  :part_within_reading

    # The most recently created check-off still present for each reader. This uses
    # three bulk queries regardless of the number of readers displayed in Admin.
    def self.recent_activity_by_reader(reader_ids)
      latest_ids = where(reader_id: reader_ids).group(:reader_id).maximum(:id).values
      latest_checkoffs = where(id: latest_ids).index_by(&:reader_id)
      day_counts = recent_activity_day_counts(latest_checkoffs.values)

      latest_checkoffs.transform_values do |checkoff|
        RecentActivity.new(
          occurred_at: checkoff.created_at,
          day: checkoff.day,
          track: checkoff.track,
          part: checkoff.part,
          day_completed?: day_counts.fetch([checkoff.reader_id, checkoff.day], 0) >= Plan.total_parts(checkoff.day)
        )
      end
    end

    def self.recent_activity_day_counts(checkoffs)
      return {} if checkoffs.empty?

      where(reader_id: checkoffs.map(&:reader_id), day: checkoffs.map(&:day)).group(:reader_id, :day).count
    end
    private_class_method :recent_activity_day_counts

  private

    def track_present_on_day
      return if day.nil? || track.nil?
      return if Plan.present_tracks(day).include?(track)

      errors.add(:track, "is not part of day #{day}")
    end

    # Part 0 is the first chapter of the day's reading; an Old Testament reading
    # of three chapters has parts 0, 1 and 2.
    def part_within_reading
      return if day.nil? || track.nil? || part.nil?
      return if Plan.valid_part?(day, track, part)

      errors.add(:part, "is not part of the #{track} reading on day #{day}")
    end
  end
end
