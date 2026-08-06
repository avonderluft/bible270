# frozen_string_literal: true

module Bible270
  # A publicly visible reflection attached to a plan day (optionally a track).
  class Comment < ApplicationRecord
    self.table_name = 'bible270_comments'

    belongs_to :reader, class_name: 'Bible270::Reader'

    # One level of replies. dependent: :destroy, because a reply to a deleted
    # reflection has nothing left to answer.
    belongs_to :parent, class_name: 'Bible270::Comment', optional: true
    has_many :replies, class_name: 'Bible270::Comment', foreign_key: :parent_id,
                       dependent: :destroy, inverse_of: :parent

    validates :day, inclusion: { in: 1..Plan::DAYS }
    validates :body, presence: true, length: { maximum: 4000 }
    # A reflection can be about one track or about the whole day. The form's
    # "The whole day" option submits an empty string, so normalise it to NULL
    # before validating — allow_nil alone rejects "" with
    # "Track is not included in the list".
    before_validation :normalize_track

    validates :track, inclusion: { in: Plan::TRACKS.keys }, allow_blank: true
    validate :parent_is_a_top_level_reflection
    validate :parent_is_on_the_same_day

    # Fires once the reflection is really saved, so nothing is sent for one whose
    # transaction rolls back.
    after_create_commit :notify_mentioned_readers
    # Only the people newly named: editing a reflection five times must not mail
    # the same reader five times.
    after_update_commit :notify_newly_mentioned_readers

    scope :approved, -> { where(approved: true) }
    scope :hidden,   -> { where(approved: false) }
    # Only the reflections themselves: replies are rendered under their parent, so
    # listing them again at the top level would show each twice.
    scope :for_day,  ->(d) { approved.where(day: d, parent_id: nil).order(created_at: :asc) }
    scope :threads_for_day, ->(d) { for_day(d).includes(:reader, replies: :reader) }
    scope :recent, -> { approved.order(created_at: :desc) }

    # Every reflection is visible when written; these are the moderation actions.
    def hide!    = update!(approved: false, moderated_at: Time.current)
    def unhide!  = update!(approved: true,  moderated_at: Time.current)
    def hidden?  = !approved
    def reply?   = parent_id.present?

    # A second's grace: created_at and updated_at differ by microseconds on
    # insert, which would mark every reflection as edited.
    def edited?  = updated_at - created_at > 1

    # Visible replies, oldest first: a conversation reads forwards.
    def visible_replies = replies.approved.order(created_at: :asc)
    def moderated? = moderated_at.present?

  private

    def normalize_track
      self.track = Plan.normalize_track(track)
    end

    # A reply to a reply would make a tree, and with it the questions of how deep
    # to indent and what hiding a middle node means. One level avoids all of that.
    def parent_is_a_top_level_reflection
      return if parent.nil?
      return if parent.parent_id.nil?

      errors.add(:parent, 'is itself a reply')
    end

    def parent_is_on_the_same_day
      return if parent.nil? || parent.day == day

      errors.add(:parent, "is on day #{parent.day}, not #{day}")
    end

    # A mention emails the person named. Failures are logged rather than raised:
    # nobody should lose a reflection because the mail server is down.
    def notify_newly_mentioned_readers
      return unless saved_change_to_body?

      already = Reader.mentioned_in(body_before_last_save).map(&:id)
      notify_mentioned_readers(except: already)
    end

    def notify_mentioned_readers(except: [])
      return unless Bible270.config.mention_notifications

      Reader.mentioned_in(body).each do |mentioned|
        next if mentioned.id == reader_id
        next if except.include?(mentioned.id)
        next unless mentioned.wants_mention_notices?

        notice = NoticeMailer.mentioned(comment_id: id, reader_id: mentioned.id)
        Bible270.config.registration_notice_deliver_later ? notice.deliver_later : notice.deliver_now
      end
    rescue StandardError => e
      Rails.logger.error("[bible270] could not send mention notices for comment #{id}: #{e.class}: #{e.message}")
    end
  end
end
