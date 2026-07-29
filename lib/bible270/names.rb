# frozen_string_literal: true

module Bible270
  # Readers are known to each other by name beside their reflections, so a first
  # and last name are both required wherever a name is set: at email sign-in, when
  # a reader edits their own, and when an admin edits someone else's.
  #
  # Kept free of Rails so the rules can be tested on their own.
  module Names
    module_function

    # Collapse runs of whitespace, including the non-breaking space that arrives
    # from copy-paste, and trim.
    def squish(value)
      value.to_s.tr("\u00A0", ' ').gsub(/\s+/, ' ').strip
    end

    # A first and last name, or nil when either is missing. Returns the pieces
    # plus the display name built from them, so every caller derives it the same
    # way rather than assembling it locally.
    def normalize(first, last)
      first_name = squish(first)
      last_name  = squish(last)
      return nil if first_name.empty? || last_name.empty?

      {
        first_name: first_name,
        last_name: last_name,
        display_name: "#{first_name} #{last_name}"
      }
    end

    def valid?(first, last)
      !normalize(first, last).nil?
    end

    # Best effort at splitting a single name, for readers who arrived through
    # OmniAuth with only a display name. Everything after the first word is the
    # surname, so "Andrew von der Luft" keeps its particles together.
    def split(display_name)
      parts = squish(display_name).split(' ')
      return nil if parts.size < 2

      { first_name: parts.first, last_name: parts[1..].join(' ') }
    end
  end
end
