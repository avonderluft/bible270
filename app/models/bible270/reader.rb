# frozen_string_literal: true

module Bible270
  # A reader identity. Either self-contained (created via OmniAuth) or bridged
  # to one of the host application's users through the polymorphic :owner.
  class Reader < ApplicationRecord
    self.table_name = 'bible270_readers'

    has_many :checkoffs, class_name: 'Bible270::Checkoff', dependent: :destroy
    has_many :comments,  class_name: 'Bible270::Comment',  dependent: :destroy
    belongs_to :owner, polymorphic: true, optional: true

    # Active Storage is optional: an app may have it disabled, and the engine has
    # to keep working there — readers simply can't upload, and any avatar from
    # their sign-in provider is used instead.
    AVATAR_UPLOADS = respond_to?(:has_one_attached)
    has_one_attached :avatar if AVATAR_UPLOADS

    def self.avatar_uploads? = AVATAR_UPLOADS

    validates :display_name, presence: true
    validates :uid, uniqueness: { scope: :provider }, allow_nil: true

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
      reader.save
      reader
    end

    # Find or create the reader behind a verified email address. Uses the same
    # provider/uid identity columns as OmniAuth, with provider "email", so an
    # email reader is indistinguishable from any other downstream.
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

    def sort_name
      [last_name, first_name].map { |n| n.to_s.strip.downcase }.join(' ').strip.presence || display_name.to_s.downcase
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

      done >= Plan.required_track_count(day) ? :complete : :partial
    end

    def read_tracks_for(day)
      checkoffs.where(day: day).pluck(:track)
    end

    def read?(day, track)
      read_tracks_for(day).include?(track.to_s)
    end

    def day_complete?(day)
      n = checked_counts[day].to_i
      n.positive? && n >= Plan.required_track_count(day)
    end

    def days_completed
      checked_counts.count { |day, n| n >= Plan.required_track_count(day) }
    end

    def days_read_in(track)
      checkoffs.where(track: track.to_s).count
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

      Names.split(display_name) || { first_name: display_name, last_name: nil }
    end

    # ---- administrative adjustments --------------------------------------

    # Tick every track that has content on this day.
    def mark_day_complete!(day)
      return false unless Plan.valid_day?(day)

      Plan.present_tracks(day).each do |track|
        checkoffs.find_or_create_by!(day: day, track: track)
      end
      reload_progress
      true
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
      return false unless day.to_i.between?(0, Plan::DAYS)

      transaction do
        checkoffs.where(day: (day.to_i + 1)..).destroy_all
        (1..day.to_i).each do |d|
          Plan.present_tracks(d).each { |t| checkoffs.find_or_create_by!(day: d, track: t) }
        end
      end
      reload_progress
      true
    end

    # Put this reader on `day` as of `on` — i.e. back-date the start so that the
    # given date lands on the given day of the plan.
    def restart_on!(day:, on: Date.current)
      day = day.to_i
      return false unless Plan.valid_day?(day)

      update!(started_on: Plan.to_date(on) - (day - 1))
    end

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
      Plan.day_for(Date.current, effective_start_date)
    end

    # Raw, unclamped — lets callers distinguish "not started yet" / "finished".
    def raw_calendar_day
      Plan.day_for(Date.current, effective_start_date, clamp: false)
    end

    def not_started_yet?
      Plan.before_start?(Date.current, effective_start_date)
    end

    def past_end_date?
      Plan.after_end?(Date.current, effective_start_date)
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

    # Set the start date regardless of whether readers are allowed to set their
    # own. For administrative use: config.allow_reader_start_date governs what a
    # reader may do to themselves, not what an admin may do on their behalf.
    # Returns false only when the value isn't a date.
    def set_start_date!(value)
      date = Plan.to_date(value)
      return false if date.nil?

      update!(started_on: date)
    end

    # The reader-facing version, which does respect that permission.
    def update_start_date!(value)
      return false unless Bible270.config.allow_reader_start_date

      set_start_date!(value)
    end

    def clear_start_date!
      update!(started_on: nil)
    end

    # Called when a reader first participates. Only stamps a personal start date
    # when per-reader dates are enabled and a shared date isn't already in force.
    def ensure_started!
      config = Bible270.config
      return unless config.allow_reader_start_date
      return if started_on.present?
      return if config.start_date.present?

      update!(started_on: Date.current)
    end
  end
end
