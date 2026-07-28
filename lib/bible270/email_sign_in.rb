# frozen_string_literal: true

require 'securerandom'
require 'digest'

module Bible270
  # Pure helpers for passwordless ("magic link") email sign-in. Kept free of
  # Rails so the security-relevant bits can be unit tested on their own.
  #
  # We never store a password and never store the raw token — only a SHA-256
  # digest of it, so a leaked database can't be used to sign in.
  module EmailSignIn
    # Deliberately permissive: real validation is "did the link get clicked".
    EMAIL_RE = %r{\A[^@\s,;:<>"]+@[^@\s,;:<>"]+\.[A-Za-z]{2,}\z}

  module_function

    # Trim, strip a mailto:, and downcase. Returns nil for anything unusable.
    def normalize_email(value)
      email = value.to_s.strip
      email = email[7..] if email.downcase.start_with?('mailto:')
      email = email.strip.downcase
      return nil if email.empty?
      return nil unless email.match?(EMAIL_RE)
      return nil if email.length > 254 # RFC 5321 practical maximum

      email
    end

    def valid_email?(value)
      !normalize_email(value).nil?
    end

    # A URL-safe, high-entropy single-use token (256 bits).
    def generate_token
      SecureRandom.urlsafe_base64(32)
    end

    # What we actually persist. Hex digest keeps it index-friendly.
    def digest_token(token)
      return nil if token.to_s.empty?

      Digest::SHA256.hexdigest(token.to_s)
    end

    # Constant-time comparison, for callers that need to compare digests
    # directly rather than looking them up.
    def secure_compare(a, b)
      a = a.to_s
      b = b.to_s
      return false unless a.bytesize == b.bytesize

      res = 0
      a.bytes.zip(b.bytes) { |x, y| res |= x ^ y }
      res.zero?
    end

    # The part of an address we can use as a default display name:
    # "mary.anne.smith@example.com" => "Mary Anne Smith"
    def display_name_from(email)
      local = normalize_email(email)&.split('@')&.first
      return nil if local.nil? || local.empty?

      # NB: the hyphen must come last or tr reads "_-+" as a range.
      local.tr('._+-', ' ').split.map { |w| w[0].upcase + (w[1..] || '') }.join(' ')
    end
  end
end
