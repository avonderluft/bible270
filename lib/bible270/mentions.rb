# frozen_string_literal: true

module Bible270
  # Finding "@someone" in a reflection, and deciding who that is.
  #
  # There is no username field, so mentions match against the names readers
  # already have. Two forms are accepted, both case-insensitively:
  #
  #   @andrew                 a first name
  #   @andrew.vonderluft      first and last, joined by a dot
  #
  # A mention that matches more than one reader resolves to nobody. Guessing
  # would mean mailing the wrong person, and silence is easier to notice than a
  # misdelivered message: the writer sees their mention unlinked.
  module Mentions
    # Deliberately narrow: letters, digits, dots, hyphens and apostrophes, so
    # "@andrew," and "@andrew." at the end of a sentence still work, and an email
    # address in the body is not mistaken for a mention.
    PATTERN = %r{(?<![\w@])@([\p{L}\p{N}][\p{L}\p{N}.'-]{0,60})}

    MAX_PER_COMMENT = 10

  module_function

    # The handles written in a piece of text, normalised and de-duplicated.
    def extract(text)
      return [] if text.nil?

      text.to_s.scan(PATTERN).flatten
        .map { |handle| normalize(handle) }
        .reject(&:empty?)
        .uniq
        .first(MAX_PER_COMMENT)
    end

    # Trailing punctuation is dropped so "@andrew." and "@andrew" agree.
    def normalize(handle)
      handle.to_s.downcase.gsub(%r{[^\p{L}\p{N}.'-]}, '').sub(%r{[.'-]+\z}, '')
    end

    # Every handle a reader answers to, given their names.
    def handles_for(first_name, last_name)
      first = normalize(first_name)
      last  = normalize(last_name)
      return [] if first.empty?

      handles = [first]
      handles << "#{first}.#{last}" unless last.empty?
      handles.uniq
    end

    # The form to write when there is more than one reader with the same first
    # name: the longer handle is unambiguous.
    def preferred_handle(first_name, last_name, ambiguous: false)
      handles = handles_for(first_name, last_name)
      return nil if handles.empty?

      ambiguous ? handles.last : handles.first
    end

    # Wraps each mention so a view can style it, leaving the text otherwise
    # untouched. The block receives the handle and returns the replacement.
    def highlight(text)
      return text.to_s if text.nil?

      text.to_s.gsub(PATTERN) do
        handle = Regexp.last_match(1)
        yield(normalize(handle), "@#{handle}")
      end
    end
  end
end
