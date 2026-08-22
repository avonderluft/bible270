# frozen_string_literal: true

module Bible270
  # A publicly visible reflection attached to a plan day (optionally a track).
  class Comment < ApplicationRecord
    # One heart for both states. An unliked one is the same emoji shown grey by
    # CSS, so it cannot drift in size from a real like, and hovering it previews
    # exactly what clicking will produce.
    #
    # The white heart this replaced was legible on white but nearly invisible on
    # the paper background; an outline glyph like U+2661 is drawn by the font
    # rather than the emoji set and needs hand-tuning to match.
    HEART = '❤️'
    ThreadPage = Struct.new(:threads, :activity_by_id, :page, :pages, :total, keyword_init: true)

    self.table_name = 'bible270_comments'

    belongs_to :reader, class_name: 'Bible270::Reader'

    # One level of replies. dependent: :destroy, because a reply to a deleted
    # reflection has nothing left to answer.
    belongs_to :parent, class_name: 'Bible270::Comment', optional: true
    has_many :replies, class_name: 'Bible270::Comment', foreign_key: :parent_id,
                       dependent: :destroy, inverse_of: :parent
    has_many :likes, class_name: 'Bible270::Like', dependent: :destroy, inverse_of: :comment

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
    # transaction rolls back. Replies notify their parent author directly; explicit
    # mentions notify everyone else named in the body.
    after_create_commit :notify_comment_readers
    # Only the people newly named: editing a reflection five times must not mail
    # the same reader five times or repeat the original reply notice.
    after_update_commit :notify_newly_mentioned_readers

    scope :approved, -> { where(approved: true) }
    scope :hidden,   -> { where(approved: false) }
    # Only the reflections themselves: replies are rendered under their parent, so
    # listing them again at the top level would show each twice.
    scope :for_day,  ->(d) { approved.where(day: d, parent_id: nil).order(created_at: :asc) }
    scope :threads_for_day, ->(d) {
      for_day(d).includes(:reader, { likes: :reader }, { replies: [:reader, { likes: :reader }] })
    }
    scope :recent, -> { approved.order(created_at: :desc) }

    # One page of top-level reflections ordered by the newest activity in each
    # conversation. Loading only IDs and timestamps keeps older archives cheap to
    # sort, while the displayed page still eager-loads its readers, replies and likes.
    def self.thread_page(day: nil, reader_id: nil, page: 1, per_page: 10)
      roots = approved.where(parent_id: nil)
      roots = roots.where(day: day) if day
      roots = roots.where(reader_id: reader_id) if reader_id

      root_rows = roots.pluck(:id, :created_at)
      reply_activity = approved.where.not(parent_id: nil).group(:parent_id).maximum(:created_at)
      ordered = root_rows.map do |id, created_at|
        [id, [created_at, reply_activity[id]].compact.max]
      end
      ordered.sort_by! { |id, activity_at| [-activity_at.to_f, -id] }

      per_page = per_page.to_i
      per_page = 10 unless per_page.positive?
      pages = [(ordered.length.to_f / per_page).ceil, 1].max
      page = page.to_i.clamp(1, pages)
      page_rows = ordered.slice((page - 1) * per_page, per_page) || []
      ids = page_rows.map(&:first)
      loaded = approved.where(id: ids)
        .includes(:reader, { likes: :reader }, { replies: [:reader, { likes: :reader }] })
        .index_by(&:id)

      ThreadPage.new(
        threads: ids.filter_map { |id| loaded[id] },
        activity_by_id: page_rows.to_h,
        page: page,
        pages: pages,
        total: ordered.length
      )
    end

    # Every reflection is visible when written; these are the moderation actions.
    def hide!    = update!(approved: false, moderated_at: Time.current)
    def unhide!  = update!(approved: true,  moderated_at: Time.current)
    def hidden?  = !approved
    def reply?   = parent_id.present?

    def liked_by?(reader)
      return false if reader.nil?

      likes.any? { |like| like.reader_id == reader.id }
    end

    # Toggling returns the new state, so a caller can say what happened without
    # asking again.
    def toggle_like!(reader)
      existing = likes.find { |like| like.reader_id == reader.id }
      if existing
        existing.destroy
        likes.reload
        false
      else
        likes.create(reader: reader)
        likes.reload
        true
      end
    end

    def set_like!(reader, liked:)
      if liked
        likes.create_or_find_by!(reader: reader)
      else
        likes.where(reader: reader).destroy_all
      end
      likes.reload
      liked
    end

    # A second's grace: created_at and updated_at differ by microseconds on
    # insert, which would mark every reflection as edited.
    def edited? = updated_at - created_at > 1

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

    def notify_comment_readers
      return unless Bible270.config.mention_notifications

      replied_to = reply_notification_reader
      deliver_comment_notice(replied_to, :replied) if replied_to
      notify_mentioned_readers(except: [replied_to&.id].compact)
    end

    def notify_newly_mentioned_readers
      return unless saved_change_to_body?

      already = Reader.mentioned_in(body_before_last_save).map(&:id)
      already << parent.reader_id if reply?
      notify_mentioned_readers(except: already)
    end

    def notify_mentioned_readers(except: [])
      return unless Bible270.config.mention_notifications

      Reader.mentioned_in(body).each do |mentioned|
        next if mentioned.id == reader_id
        next if except.include?(mentioned.id)

        deliver_comment_notice(mentioned, :mentioned)
      end
    end

    def reply_notification_reader
      return unless reply?

      recipient = parent&.reader
      recipient unless recipient&.id == reader_id
    end

    # Each recipient is isolated so a mail-server failure for one person cannot
    # prevent other people named in the same reflection from being notified.
    def deliver_comment_notice(recipient, action)
      return unless recipient&.wants_comment_notifications?

      notice = NoticeMailer.public_send(action, comment_id: id, reader_id: recipient.id)
      Bible270.config.registration_notice_deliver_later ? notice.deliver_later : notice.deliver_now
    rescue StandardError => e
      Rails.logger.error(
        "[bible270] could not send #{action} notice for comment #{id}: #{e.class}: #{e.message}"
      )
    end
  end
end
