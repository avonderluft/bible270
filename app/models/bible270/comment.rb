# frozen_string_literal: true
module Bible270
  # A publicly visible reflection attached to a plan day (optionally a track).
  class Comment < ApplicationRecord
    self.table_name = "bible270_comments"

    belongs_to :reader, class_name: "Bible270::Reader"

    validates :day, inclusion: { in: 1..Plan::DAYS }
    validates :body, presence: true, length: { maximum: 4000 }
    validates :track, inclusion: { in: Plan::TRACKS.keys }, allow_nil: true

    scope :for_day, ->(d) { where(day: d).order(created_at: :asc) }
    scope :recent,  -> { order(created_at: :desc) }
  end
end
