# frozen_string_literal: true

module Bible270
  # A single reader marking one track (ot / nt / pp) read on one day.
  class Checkoff < ApplicationRecord
    self.table_name = 'bible270_checkoffs'

    belongs_to :reader, class_name: 'Bible270::Reader'

    validates :day, inclusion: { in: 1..Plan::DAYS }
    validates :track, inclusion: { in: Plan::TRACKS.keys }
    validates :track, uniqueness: { scope: %i[reader_id day] }
    validate  :track_present_on_day

  private

    def track_present_on_day
      return if day.nil? || track.nil?
      return if Plan.present_tracks(day).include?(track)

      errors.add(:track, "is not part of day #{day}")
    end
  end
end
