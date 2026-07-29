# frozen_string_literal: true

module Bible270
  # The translations a reader may choose between, and how each maps onto the
  # external reader's own code. Kept free of Rails so it can be unit tested.
  #
  # The distinction matters: readers know the NASB 1995 as "NASB95", but Bible
  # Gateway's parameter for it is "NASB1995". Sending the display code straight
  # through would land every link on a search page instead of the passage.
  module Translations
    # `label` is the full name, for prose. `short` is what goes in the select,
    # where "New American Standard Bible 1995" overflows the box.
    VERSIONS = {
      'NKJV' => { label: 'New King James Version', short: 'New King James Version', gateway: 'NKJV' },
      'NASB95' => { label: 'New American Standard Bible 1995', short: 'New American Standard 1995', gateway: 'NASB1995' },
      'LSB' => { label: 'Legacy Standard Bible', short: 'Legacy Standard Version', gateway: 'LSB' },
      'ESV' => { label: 'English Standard Version', short: 'English Standard Version', gateway: 'ESV' },
      'KJV' => { label: 'King James Version', short: 'King James Version', gateway: 'KJV' }
    }.freeze

    DEFAULT = 'NKJV'

  module_function

    # The codes offered to readers, narrowed by config.bible_versions if the host
    # only wants some of them.
    def codes
      allowed = Bible270.config.bible_versions if Bible270.config.respond_to?(:bible_versions)
      requested = Array(allowed).map { |code| code.to_s.upcase }.select { |code| VERSIONS.key?(code) }
      requested.any? ? requested : VERSIONS.keys
    end

    def valid?(code)
      codes.include?(normalize(code))
    end

    def normalize(code)
      code.to_s.strip.upcase
    end

    def label(code)
      VERSIONS.dig(normalize(code), :label)
    end

    def short_label(code)
      VERSIONS.dig(normalize(code), :short) || label(code)
    end

    # The code the external reader expects, which is not always the code readers
    # recognise.
    def gateway_code(code)
      VERSIONS.dig(normalize(code), :gateway) || normalize(code)
    end

    # [[label, code], ...] for a select field.
    def options
      codes.map { |code| ["#{code} — #{short_label(code)}", code] }
    end

    # Falls back to the configured default, then to ESV, so a link is never built
    # with a blank version.
    def resolve(code)
      return normalize(code) if valid?(code)

      configured = Bible270.config.bible_version if Bible270.config.respond_to?(:bible_version)
      return normalize(configured) if valid?(configured)

      codes.include?(DEFAULT) ? DEFAULT : codes.first
    end
  end
end
