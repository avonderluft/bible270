# frozen_string_literal: true

module Bible270
  # A reader identity. Either self-contained (created via OmniAuth) or bridged
  # to one of the host application's users through the polymorphic :owner.
  class Reader < ApplicationRecord
    self.table_name = 'bible270_readers'

    has_many :checkoffs, class_name: 'Bible270::Checkoff', dependent: :destroy
    has_many :comments,  class_name: 'Bible270::Comment',  dependent: :destroy
    has_many :likes,     class_name: 'Bible270::Like',     dependent: :destroy, inverse_of: :reader
    belongs_to :owner, polymorphic: true, optional: true

    # Active Storage is optional: an app may have it disabled, and the engine has
    # to keep working there — readers simply can't upload, and any avatar from
    # their sign-in provider is used instead.
    AVATAR_UPLOADS = respond_to?(:has_one_attached)
    has_one_attached :avatar if AVATAR_UPLOADS

    def self.avatar_uploads? = AVATAR_UPLOADS

    # Fires for every way a reader comes into existence — email sign-in, OmniAuth,
    # or a bridged host user — rather than in each controller, so no path can
    # quietly skip it. after_create_commit, so nothing is sent for a reader whose
    # transaction rolls back.
    after_create_commit :notify_of_registration

    PASSAGE_SOURCES = %w[bible_gateway blue_letter_bible].freeze
    DEFAULT_PASSAGE_SOURCE = 'bible_gateway'
    DAILY_REMINDER_TIME_FORMAT = %r{\A(?:[01]\d|2[0-3]):[0-5]\d\z}
    DAILY_REMINDER_COLUMNS = %w[daily_reminders daily_reminder_time last_daily_reminder_sent_on].freeze
    REFLECTIONS_SEEN_COLUMN = 'reflections_seen_at'

    validates :display_name, presence: true
    validates :uid, uniqueness: { scope: :provider }, allow_nil: true
    validates :passage_source, inclusion: { in: PASSAGE_SOURCES }
    validates :daily_reminder_time,
              format: { with: DAILY_REMINDER_TIME_FORMAT, message: 'must use 24-hour HH:MM format' },
              if: -> { self.class.daily_reminder_columns? }

    scope :daily_reminder_recipients, ->(on:) {
      where(daily_reminders: true)
        .where.not(email: [nil, ''])
        .where.not(id: where(last_daily_reminder_sent_on: on).select(:id))
    }

    def self.daily_reminder_columns?
      (DAILY_REMINDER_COLUMNS - column_names).empty?
    rescue ActiveRecord::StatementInvalid
      false
    end

    def self.valid_daily_reminder_time?(value)
      value.to_s.match?(DAILY_REMINDER_TIME_FORMAT)
    end

    def self.reflections_seen_column?
      column_names.include?(REFLECTIONS_SEEN_COLUMN)
    rescue ActiveRecord::StatementInvalid
      false
    end

    def mark_reflections_seen!(at)
      return false unless self.class.reflections_seen_column?

      update_column(:reflections_seen_at, at)
      true
    rescue ActiveRecord::StatementInvalid
      false
    end

    def daily_reminder_due_at?(local_time)
      return false unless self.class.daily_reminder_columns?
      return false unless daily_reminders?
      return false unless self.class.valid_daily_reminder_time?(daily_reminder_time)
      return false unless local_time.respond_to?(:hour) && local_time.respond_to?(:min)

      hour, minute = daily_reminder_time.split(':').map(&:to_i)
      (local_time.hour * 60) + local_time.min >= (hour * 60) + minute
    rescue StandardError
      false
    end

    # Build/refresh a reader from an OmniAuth auth hash. Tolerant of the various
    # shapes strategies return (OmniAuth::AuthHash, plain Hash, missing info).
    def self.from_omniauth(auth)
      provider = dig_auth(auth, :provider).to_s
      uid      = dig_auth(auth, :uid).to_s
      return nil if provider.empty? || uid.empty?

      info = dig_auth(auth, :info) || {}
      name = first_present(dig_auth(info, :name), dig_auth(info, :nickname),
                           dig_auth(info, :first_name), dig_auth(info, :email))

      reader = find_or_initialize_by(provider: provider, uid: uid)
      reader.display_name = first_present(name, reader.display_name, 'Reader')
      email = dig_auth(info, :email)
      image = first_present(dig_auth(info, :image), dig_auth(info, :avatar_url))
      reader.email      = email if email.present?
      reader.avatar_url = image if image.present?
      assign_names_from(reader, info)
      reader.save
      reader
    end

    # Providers hand back one display name far more often than two fields, so the
    # name is split when they do not. Without this an OmniAuth reader had no
    # first_name — which made the greeting read "Welcome ." and, more seriously,
    # made them unmentionable: Reader.mentioned_in only considers readers who have
    # one.
    #
    # Only filled in when empty, so a reader who has since corrected their name on
    # their profile does not have it overwritten at every sign-in.
    def self.assign_names_from(reader, info)
      return if reader.first_name.present?

      given = dig_auth(info, :first_name)
      family = dig_auth(info, :last_name)

      if given.present?
        reader.first_name = given
        reader.last_name = family
        return
      end

      split = Names.split_display_name(reader.display_name)
      reader.first_name = split ? split[:first_name] : reader.display_name.to_s.split.first
      reader.last_name = split ? split[:last_name] : nil
    end
    private_class_method :assign_names_from

    # Find or create the reader behind a verified email address. Uses the same
    # provider/uid identity columns as OmniAuth, with provider "email", so an
    # email reader is indistinguishable from any other downstream.
    # Used when enrolment is closed: an existing reader may still sign in, a new
    # one may not be created.
    def self.email_reader_exists?(email)
      address = EmailSignIn.normalize_email(email)
      return false if address.nil?

      exists?(provider: 'email', uid: address)
    end

    def self.omniauth_reader_exists?(provider, uid)
      return false if provider.blank? || uid.blank?

      exists?(provider: provider.to_s, uid: uid.to_s)
    end

    def self.from_email(email, first_name: nil, last_name: nil, display_name: nil)
      address = EmailSignIn.normalize_email(email)
      return nil if address.nil?

      reader = find_or_initialize_by(provider: 'email', uid: address)
      reader.first_name = first_name.to_s.strip if first_name.present?
      reader.last_name  = last_name.to_s.strip  if last_name.present?
      reader.display_name = first_present(reader.full_name, display_name, reader.display_name,
                                          EmailSignIn.display_name_from(address), 'Reader')
      reader.email = address
      reader.save
      reader
    end

    def self.dig_auth(obj, key)
      return nil if obj.nil?

      if obj.respond_to?(:[])
        obj[key] || (obj[key.to_s] if key.is_a?(Symbol))
      elsif obj.respond_to?(key)
        obj.public_send(key)
      end
    rescue StandardError
      nil
    end
    private_class_method :dig_auth

    def self.first_present(*values)
      values.compact.find { |v| v.to_s.strip != '' }
    end
    private_class_method :first_present

    # Find or create a reader bridged to a host user (or any model).
    def self.for_owner(owner, display_name:, email: nil, avatar_url: nil)
      reader = find_or_initialize_by(owner: owner)
      reader.display_name = display_name.presence || reader.display_name || 'Reader'
      reader.email      ||= email
      reader.avatar_url ||= avatar_url
      reader.save!
      reader
    end

    def full_name
      [first_name, last_name].map { |n| n.to_s.strip }.reject(&:empty?).join(' ').presence
    end

    # Shorter than the full name, for lists where a surname is more than needed.
    # Falls back to the display name for readers who arrived with only one.
    def first_with_last_initial
      return display_name if first_name.blank?

      Names.first_with_last_initial(first_name, last_name).presence || display_name
    end

    # The translation this reader reads in. Null means "whatever the site default
    # is", so changing config.bible_version moves everyone who hasn't chosen.
    def effective_bible_version
      Translations.resolve(bible_version)
    end

    def bible_version_label
      Translations.label(effective_bible_version)
    end

    def update_bible_version(code)
      return false unless Translations.valid?(code)

      update(bible_version: Translations.normalize(code))
    end

    def update_passage_source(source)
      source = source.to_s
      return false unless PASSAGE_SOURCES.include?(source)

      update(passage_source: source)
    end

    def bible_gateway? = passage_source == 'bible_gateway'
    def blue_letter_bible? = passage_source == 'blue_letter_bible'

    # Readers are listed by first name, matching how they are shown — the display
    # name is "First Last", so sorting on it needs only case folding. Surname
    # order was inconsistent with the community page and read oddly next to names
    # displayed first-name-first.
    def sort_name
      display_name.to_s.strip.downcase
    end

    # ---- mentions ----------------------------------------------------------

    # Older copied databases may briefly lack the preference column while their
    # migrations are being reconciled. Preserve the historical opted-in behavior
    # until the column is available rather than breaking reflection delivery.
    def wants_comment_notifications?
      !has_attribute?(:notify_on_mention) || self[:notify_on_mention] != false
    end

    # The readers a piece of text mentions. A handle matching more than one reader
    # resolves to nobody: mailing the wrong person is worse than mailing none, and
    # the writer sees the mention left unlinked.
    def self.mentioned_in(text)
      handles = Mentions.extract(text)
      return [] if handles.empty?

      candidates = where.not(first_name: [nil, '']).to_a
      handles.filter_map do |handle|
        matches = candidates.select { |reader| reader.answers_to?(handle) }
        matches.first if matches.one?
      end.uniq
    end

    def answers_to?(handle)
      Mentions.handles_for(first_name, last_name).include?(handle)
    end

    # ---- staying signed in -------------------------------------------------

    # Generated on first use rather than at sign-up, so readers who never stay
    # signed in never carry one.
    def remember_token!
      return remember_token if remember_token.present?

      token = SecureRandom.urlsafe_base64(32)
      update_column(:remember_token, token)
      token
    end

    # Rotating the token invalidates every device at once.
    def forget!
      update_column(:remember_token, nil)
      true
    end

    def self.from_remember_cookie(reader_id, token)
      return nil if reader_id.blank? || token.blank?

      reader = find_by(id: reader_id)
      return nil if reader.nil? || reader.remember_token.blank?

      # Constant-time comparison: the token is a credential.
      return nil unless ActiveSupport::SecurityUtils.secure_compare(reader.remember_token, token.to_s)

      reader
    end

    def avatar_uploaded?
      self.class.avatar_uploads? && avatar.attached?
    end

    # Returns false and sets an error when the upload isn't acceptable.
    def attach_avatar(upload)
      return false unless self.class.avatar_uploads?

      problem = Avatars.problem_with(content_type: upload.content_type, byte_size: upload.size)
      if problem
        errors.add(:avatar, problem)
        return false
      end

      avatar.attach(upload)
      true
    end

    def remove_avatar!
      avatar.purge if avatar_uploaded?
      true
    end

    def initials
      display_name.to_s.split(%r{\s+}).first(2).map { |w| w[0] }.join.upcase.presence || '?'
    end

    # {day => number of tracks checked off}
    def checked_counts
      @checked_counts ||= checkoffs.group(:day).count
    end

    # Tracks ticked on a day, counted from the single grouped query in
    # checked_counts. Use this rather than read_tracks_for when rendering a grid:
    # read_tracks_for costs a query per day, which is 270 of them per page.
    def checked_count(day)
      checked_counts[day].to_i
    end

    def day_status(day)
      done = checked_count(day)
      return :none if done.zero?

      done >= Plan.total_parts(day) ? :complete : :partial
    end

    def partial_days
      checked_counts.keys.select { |day| day_status(day) == :partial }.sort
    end

    def remaining_parts_for(day)
      return [] unless Plan.valid_day?(day)

      missing_parts_on(day).map do |track, part|
        { track: track, part: part, reference: Plan.parts_for(day, track).fetch(part) }
      end
    end

    def read_tracks_for(day)
      checkoffs.where(day: day).pluck(:track).uniq
    end

    # Which chapters of a track the reader has ticked on this day.
    def read_parts_for(day, track)
      checkoffs.where(day: day, track: track.to_s).pluck(:part)
    end

    def read?(day, track, part = nil)
      return read_parts_for(day, track).include?(part) if part

      # No part given: the track counts as read only when every chapter is.
      read_parts_for(day, track).size >= Plan.part_count(day, track)
    end

    def track_partially_read?(day, track)
      done = read_parts_for(day, track).size
      done.positive? && done < Plan.part_count(day, track)
    end

    def day_complete?(day)
      n = checked_counts[day].to_i
      n.positive? && n >= Plan.total_parts(day)
    end

    def days_completed
      checked_counts.count { |day, n| n >= Plan.total_parts(day) }
    end

    # Days on which this track is *finished*. Counting rows would count chapters
    # now that an Old Testament reading has one per chapter.
    def days_read_in(track)
      checkoffs.where(track: track.to_s).group(:day).count
        .count { |day, done| done >= Plan.part_count(day, track) }
    end

    def completion_percent
      (days_completed.to_f / Plan::DAYS * 100).round
    end

    # First day not yet fully complete (where the reader "is").
    def current_day
      (1..Plan::DAYS).find { |d| !day_complete?(d) } || Plan::DAYS
    end

    # Day number implied by the calendar, if a start date is set.
    # Set the name shown beside this reader's reflections. Returns false when
    # either half is missing, so callers can re-render with a message.
    def update_names(first, last)
      names = Names.normalize(first, last)
      return false if names.nil?

      update(**names)
    end

    # Fill first/last from the display name where we only have one string, e.g.
    # a reader who arrived through OmniAuth.
    def suggested_names
      return { first_name: first_name, last_name: last_name } if full_name

      Names.split_display_name(display_name) || { first_name: display_name, last_name: nil }
    end

    # ---- administrative adjustments --------------------------------------

    # Tick every track that has content on this day.
    def mark_day_complete!(day)
      return false unless Plan.valid_day?(day)

      # Deliberately not find_or_create_by!: since Rails 8.1 that creates first
      # and rescues RecordNotUnique, but Checkoff validates uniqueness, so a
      # duplicate raises RecordInvalid before the database is reached and is
      # never rescued. Reading what exists first is also one query per day rather
      # than one per chapter.
      missing = missing_parts_on(day)
      insert_checkoffs(day, missing) if missing.any?

      reload_progress
      true
    end

    # [[track, part], ...] not yet ticked on this day.
    def missing_parts_on(day)
      wanted = Plan.present_tracks(day).flat_map do |track|
        Array.new(Plan.part_count(day, track)) { |part| [track, part] }
      end
      have = checkoffs.where(day: day).pluck(:track, :part)

      wanted - have
    end

    def insert_checkoffs(day, pairs)
      now = Time.current
      Checkoff.insert_all(
        pairs.map do |track, part|
          { reader_id: id, day: day, track: track, part: part, created_at: now, updated_at: now }
        end
      )
    end

    def clear_day!(day)
      return false unless Plan.valid_day?(day)

      checkoffs.where(day: day).destroy_all
      reload_progress
      true
    end

    def toggle_day!(day)
      day_complete?(day) ? clear_day!(day) : mark_day_complete!(day)
    end

    # Mark everything up to and including `day` complete, and clear anything after.
    def mark_through!(day)
      day = day.to_i
      return false unless day.between?(0, Plan::DAYS)

      transaction do
        checkoffs.where(day: (day + 1)..).delete_all
        (1..day).each { |d| mark_day_complete!(d) }
      end
      reload_progress
      true
    end

    # Put this reader on `day` as of `on` — i.e. back-date the start so that the
    # given date lands on the given day of the plan.
    def restart_on!(day:, on: Bible270.today)
      day = day.to_i
      return false unless Plan.valid_day?(day)

      update!(started_on: Plan.to_date(on) - (day - 1))
    end

    # Delivery problems must never stop someone joining, so this logs rather than
    # raises. Registration happens mid-request, hence the deliver_later option.
    def notify_of_registration
      recipients = Bible270.config.registration_notice_recipients
      return if recipients.empty?

      notice = NoticeMailer.new_reader(reader_id: id, recipients: recipients)
      if Bible270.config.registration_notice_deliver_later
        notice.deliver_later
      else
        notice.deliver_now
      end
    rescue StandardError => e
      Rails.logger.error("[bible270] could not send the registration notice for #{id}: #{e.class}: #{e.message}")
    end
    # Private, but declared this way rather than with a `private` section: methods
    # defined below here are called from controllers and views.
    private :notify_of_registration
    private :missing_parts_on, :insert_checkoffs

    def reload_progress
      @checked_counts = nil
      self
    end

    # ---- start date / calendar ------------------------------------------

    # The start date that actually governs this reader. A reader's own
    # started_on wins when per-reader dates are allowed; otherwise (or if they
    # haven't got one) the community-wide config.start_date applies. Nil means
    # the plan is undated for this reader and no calendar mapping exists.
    def effective_start_date
      config = Bible270.config
      if config.allow_reader_start_date && started_on
        started_on
      else
        config.start_date
      end
    end

    def dated?
      effective_start_date.present?
    end

    # Whether this reader is following a personal date or the shared cohort one.
    def own_start_date?
      Bible270.config.allow_reader_start_date && started_on.present?
    end

    # The plan day that today corresponds to (clamped into range), or nil when undated.
    def calendar_day
      Plan.day_for(Bible270.today, effective_start_date)
    end

    # Raw, unclamped — lets callers distinguish "not started yet" / "finished".
    # The plan day that today actually is, or nil when today falls outside the
    # plan's window. calendar_day clamps, so before the start date it reports day
    # 1 — which made day 1 claim to be "today" for anyone whose plan hadn't begun.
    def today_day
      raw = raw_calendar_day
      return nil if raw.nil?

      Plan.valid_day?(raw) ? raw : nil
    end

    def today?(day)
      today_day == day
    end

    def raw_calendar_day
      Plan.day_for(Bible270.today, effective_start_date, clamp: false)
    end

    def not_started_yet?
      Plan.before_start?(Bible270.today, effective_start_date)
    end

    def past_end_date?
      Plan.after_end?(Bible270.today, effective_start_date)
    end

    def plan_end_date
      Plan.end_date_for(effective_start_date)
    end

    def date_for_day(day)
      Plan.date_for(day, effective_start_date)
    end

    # How many days behind (positive) or ahead (negative) of the calendar the
    # reader's actual progress is. Nil when undated.
    def days_off_pace
      today = calendar_day
      return nil unless today

      today - days_completed
    end

    # Set or change this reader's own start date. Accepts a Date or a string.
    def start_date=(value)
      self.started_on = Plan.to_date(value)
    end

    def start_date
      started_on
    end

    # Set an individual start date for administrative use. This remains ungated
    # so an administrator can prepare or preserve a personal calendar even when
    # config.allow_reader_start_date currently makes the community date authoritative.
    # Returns false only when the value isn't a date.
    def set_start_date!(value)
      date = Plan.to_date(value)
      return false if date.nil?

      update!(started_on: date)
    end

    # Called when a reader first participates. Only stamps a personal start date
    # when per-reader dates are enabled and a shared date isn't already in force.
    def ensure_started!
      config = Bible270.config
      return unless config.allow_reader_start_date
      return if started_on.present?
      return if config.start_date.present?

      update!(started_on: Bible270.today)
    end
  end
end
