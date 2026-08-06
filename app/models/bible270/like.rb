# frozen_string_literal: true

module Bible270
  # A reader's heart on a reflection. There is nothing to a like but who gave it
  # and when — the count is the number of rows, and the hover text is the name.
  class Like < ApplicationRecord
    self.table_name = 'bible270_likes'

    belongs_to :reader, class_name: 'Bible270::Reader'
    belongs_to :comment, class_name: 'Bible270::Comment'

    validates :reader_id, uniqueness: { scope: :comment_id }
  end
end
