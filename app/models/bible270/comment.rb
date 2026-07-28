# frozen_string_literal: true

module Bible270
  # A publicly visible reflection attached to a plan day (optionally a track).
  class Comment < ApplicationRecord
    self.table_name = 'bible270_comments'

    belongs_to :reader, class_name: 'Bible270::Reader'

    validates :day, inclusion: { in: 1..Plan::DAYS }
    validates :body, presence: true, length: { maximum: 4000 }
    # A reflection can be about one track or about the whole day. The form's
    # "The whole day" option submits an empty string, so normalise it to NULL
    # before validating — allow_nil alone rejects "" with
    # "Track is not included in the list".
    before_validation :normalize_track

    validates :track, inclusion: { in: Plan::TRACKS.keys }, allow_blank: true

    scope :approved, -> { where(approved: true) }
    scope :hidden,   -> { where(approved: false) }
    scope :for_day,  ->(d) { approved.where(day: d).order(created_at: :asc) }
    scope :recent,   -> { approved.order(created_at: :desc) }

    # Every reflection is visible when written; these are the moderation actions.
    def hide!    = update!(approved: false, moderated_at: Time.current)
    def unhide!  = update!(approved: true,  moderated_at: Time.current)
    def hidden?  = !approved
    def moderated? = moderated_at.present?

  private

    def normalize_track
      self.track = Plan.normalize_track(track)
    end
  end
end
