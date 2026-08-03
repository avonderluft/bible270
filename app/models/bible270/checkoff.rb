# frozen_string_literal: true

module Bible270
  # A single reader marking one track (ot / nt / pp) read on one day.
  class Checkoff < ApplicationRecord
    self.table_name = 'bible270_checkoffs'

    belongs_to :reader, class_name: 'Bible270::Reader'

    validates :day, inclusion: { in: 1..Plan::DAYS }
    validates :track, inclusion: { in: Plan::TRACKS.keys }
    validates :track, uniqueness: { scope: %i[reader_id day part] }
    validates :part, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate  :track_present_on_day
    validate  :part_within_reading

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
