# frozen_string_literal: true
module Bible270
  # A single-use, short-lived magic-link token for email sign-in.
  #
  # Only the SHA-256 digest of the token is stored, so the table is useless to
  # an attacker who reads it. Tokens are consumed on first successful use.
  class SignInToken < ApplicationRecord
    self.table_name = "bible270_sign_in_tokens"

    validates :email, presence: true
    validates :token_digest, presence: true, uniqueness: true
    validates :expires_at, presence: true

    scope :unconsumed, -> { where(consumed_at: nil) }
    scope :live, -> { unconsumed.where(expires_at: Time.current..) }

    # Issue a token for an email. Returns [token_record, raw_token], or
    # [nil, nil] when the address is being hammered (see rate_limited?).
    def self.issue!(email, display_name: nil)
      address = EmailSignIn.normalize_email(email)
      return [nil, nil] if address.nil?
      return [nil, nil] if rate_limited?(address)

      raw = EmailSignIn.generate_token
      record = create!(
        email: address,
        display_name: display_name.presence,
        token_digest: EmailSignIn.digest_token(raw),
        expires_at: Time.current + Bible270.config.email_sign_in_ttl
      )
      [record, raw]
    end

    # Look up a raw token and consume it. Returns the token record on success
    # (carrying email and any requested display name), nil for anything
    # invalid, expired, or already used.
    def self.claim!(raw_token)
      digest = EmailSignIn.digest_token(raw_token)
      return nil if digest.nil?

      record = live.find_by(token_digest: digest)
      return nil if record.nil?

      # Consume it: only the update that actually flips the row wins, so a
      # double-clicked link can't sign in twice.
      claimed = unconsumed.where(id: record.id).update_all(consumed_at: Time.current)
      return nil if claimed.zero?

      record
    end

    # Too many outstanding requests for one address in the window.
    def self.rate_limited?(address)
      window = Bible270.config.email_sign_in_window
      max    = Bible270.config.email_sign_in_max_per_window
      where(email: address).where(created_at: (Time.current - window)..).count >= max
    end

    # Housekeeping: drop spent and stale rows. Safe to run from a cron/rake task.
    def self.sweep!(older_than: 7 * 24 * 60 * 60)
      where(expires_at: ...Time.current).or(where.not(consumed_at: nil))
        .where(created_at: ...(Time.current - older_than))
        .delete_all
    end

    def expired?
      expires_at.nil? || expires_at < Time.current
    end

    def consumed?
      consumed_at.present?
    end
  end
end
