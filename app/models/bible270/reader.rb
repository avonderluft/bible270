# frozen_string_literal: true
module Bible270
  # A reader identity. Either self-contained (created via OmniAuth) or bridged
  # to one of the host application's users through the polymorphic :owner.
  class Reader < ApplicationRecord
    self.table_name = "bible270_readers"

    has_many :checkoffs, class_name: "Bible270::Checkoff", dependent: :destroy
    has_many :comments,  class_name: "Bible270::Comment",  dependent: :destroy
    belongs_to :owner, polymorphic: true, optional: true

    validates :display_name, presence: true
    validates :uid, uniqueness: { scope: :provider }, allow_nil: true

    # Build/refresh a reader from an OmniAuth auth hash. Tolerant of the various
    # shapes strategies return (OmniAuth::AuthHash, plain Hash, missing info).
    def self.from_omniauth(auth)
      provider = dig_auth(auth, :provider).to_s
      uid      = dig_auth(auth, :uid).to_s
      return nil if provider.empty? || uid.empty?

      info = dig_auth(auth, :info) || {}
      name  = first_present(dig_auth(info, :name), dig_auth(info, :nickname),
                            dig_auth(info, :first_name), dig_auth(info, :email))

      reader = find_or_initialize_by(provider: provider, uid: uid)
      reader.display_name = first_present(name, reader.display_name, "Reader")
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
    def self.from_email(email, display_name: nil)
      address = EmailSignIn.normalize_email(email)
      return nil if address.nil?

      reader = find_or_initialize_by(provider: "email", uid: address)
      chosen = first_present(display_name, reader.display_name,
                             EmailSignIn.display_name_from(address), "Reader")
      reader.display_name = chosen
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
      values.compact.find { |v| v.to_s.strip != "" }
    end
    private_class_method :first_present

    # Find or create a reader bridged to a host user (or any model).
    def self.for_owner(owner, display_name:, email: nil, avatar_url: nil)
      reader = find_or_initialize_by(owner: owner)
      reader.display_name = display_name.presence || reader.display_name || "Reader"
      reader.email      ||= email
      reader.avatar_url ||= avatar_url
      reader.save!
      reader
    end

    def initials
      display_name.to_s.split(/\s+/).first(2).map { |w| w[0] }.join.upcase.presence || "?"
    end

    # {day => number of tracks checked off}
    def checked_counts
      @checked_counts ||= checkoffs.group(:day).count
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

    def update_start_date!(value)
      return false unless Bible270.config.allow_reader_start_date

      date = Plan.to_date(value)
      return false if date.nil?

      update!(started_on: date)
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
