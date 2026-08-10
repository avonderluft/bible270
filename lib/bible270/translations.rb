# frozen_string_literal: true

require 'uri'
require 'bible270/versification'

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
      'NKJV' => { label: 'New King James Version', short: 'New King James Version', gateway: 'NKJV', blue_letter: 'nkjv' },
      'NASB95' => { label: 'New American Standard Bible 1995', short: 'New American Standard 1995', gateway: 'NASB1995', blue_letter: 'nasb95' },
      'LSB' => { label: 'Legacy Standard Bible', short: 'Legacy Standard Version', gateway: 'LSB', blue_letter: 'lsb' },
      'ESV' => { label: 'English Standard Version', short: 'English Standard Version', gateway: 'ESV', blue_letter: 'esv' },
      'KJV' => { label: 'King James Version', short: 'King James Version', gateway: 'KJV', blue_letter: 'kjv' },
      'HEB/GRK' => { label: 'Hebrew and Greek', short: 'Hebrew and Greek', gateway: 'WLC', blue_letter: 'wlc/mgnt' }
    }.freeze

    DEFAULT = 'NKJV'
    ORIGINAL_LANGUAGES = 'HEB/GRK'
    BLUE_LETTER_BASE_URL = 'https://www.blueletterbible.org'
    BLUE_LETTER_BOOK_CODES = %w[
      gen exo lev num deu jos jdg rut 1sa 2sa 1ki 2ki 1ch 2ch ezr neh est job psa pro ecc sng
      isa jer lam eze dan hos joe amo oba jon mic nah hab zep hag zec mal mat mar luk joh act rom
      1co 2co gal eph php col 1th 2th 1ti 2ti tit phm heb jas 1pe 2pe 1jo 2jo 3jo jud rev
    ].freeze

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

    def passage_url(reference, version, blue_letter: false)
      if blue_letter || normalize(version) == ORIGINAL_LANGUAGES
        return blue_letter_url(reference, version)
      end

      search = URI.encode_www_form_component(reference)
      gateway = URI.encode_www_form_component(gateway_code(version))
      "https://www.biblegateway.com/passage/?search=#{search}&version=#{gateway}"
    end

    # Blue Letter Bible identifies a verse with its canonical chapter number times
    # 1,000 plus the verse number: Genesis 1:1 is 1001 and Matthew 1:1 is 930001.
    # A plan reference can span chapters or books; BLB has no equivalent passage
    # query URL, so link to the first chapter/verse and let its chapter navigation
    # carry the reader onward.
    def blue_letter_url(reference, version = ORIGINAL_LANGUAGES)
      books = Versification::VERSES.keys
      book_index = books.index { |book| reference.to_s.start_with?("#{book} ") }
      return "#{BLUE_LETTER_BASE_URL}/" unless book_index

      book = books[book_index]
      location = reference.to_s.delete_prefix("#{book} ")
      match = location.match(%r{\A(\d+)(?::(\d+))?})
      return "#{BLUE_LETTER_BASE_URL}/" unless match

      chapter = match[1].to_i
      verse = match[2]&.to_i || 1
      chapter_verses = Versification::VERSES[book]
      return "#{BLUE_LETTER_BASE_URL}/" unless chapter.between?(1, chapter_verses.length)
      return "#{BLUE_LETTER_BASE_URL}/" unless verse.between?(1, chapter_verses[chapter - 1])

      canonical_chapter = books.first(book_index).sum { |prior| Versification::VERSES[prior].length } + chapter
      new_testament = book_index >= books.index('Matthew')
      reader = if normalize(version) == ORIGINAL_LANGUAGES
                 new_testament ? 'mgnt' : 'wlc'
               else
                 VERSIONS.dig(normalize(version), :blue_letter)
               end
      return "#{BLUE_LETTER_BASE_URL}/" if reader.to_s.empty?

      anchor = (canonical_chapter * 1000) + verse
      "#{BLUE_LETTER_BASE_URL}/#{reader}/#{BLUE_LETTER_BOOK_CODES[book_index]}/" \
        "#{chapter}/#{verse}/s_#{anchor}"
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
