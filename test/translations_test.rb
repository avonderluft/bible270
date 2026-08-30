# frozen_string_literal: true

require 'test_helper'
require 'bible270/configuration'
require 'bible270/translations'

class TranslationsTest < Minitest::Test
  T = Bible270::Translations

  def setup
    @previous_versions = Bible270.config.bible_versions
    @previous_default  = Bible270.config.bible_version
  end

  def teardown
    Bible270.config.bible_versions = @previous_versions
    Bible270.config.bible_version  = @previous_default
  end

  def test_the_offered_translations
    assert_equal %w[NKJV NASB95 LSB ESV KJV YLT HEB/GRK ALLGRK], T::VERSIONS.keys
  end

  def test_every_translation_declares_what_the_code_needs
    T::VERSIONS.each do |code, entry|
      %i[label short gateway blue_letter].each do |key|
        refute_nil entry[key], "#{code} is missing :#{key}"
        refute_empty entry[key].to_s, "#{code} has an empty :#{key}"
      end
    end
  end

  def test_every_english_translation_has_a_bible_com_mapping
    assert_equal T::VERSIONS.keys - T::ORIGINAL_LANGUAGE_CODES, T::BIBLE_COM_VERSIONS.keys
    T::BIBLE_COM_VERSIONS.each_value do |version_id, version_code|
      assert_predicate version_id, :positive?
      refute_empty version_code
    end
  end

  def test_bible_com_book_codes_follow_the_versification_books
    assert_equal Bible270::Versification::VERSES.size, T::BIBLE_COM_BOOK_CODES.size
    selected_codes = [0, 18, 39, 40, 42, 61, 65].map { |index| T::BIBLE_COM_BOOK_CODES[index] }
    assert_equal %w[GEN PSA MAT MRK JHN 1JN REV], selected_codes
  end

  def test_kjv_maps_to_itself
    assert T.valid?('KJV')
    assert_equal 'KJV', T.gateway_code('KJV')
    assert_equal 'King James Version', T.label('KJV')
  end

  # The whole reason this module exists: readers know it as NASB95, Bible Gateway
  # wants NASB1995. Sending the display code through would break every link.
  def test_nasb95_maps_to_bible_gateways_own_code
    assert_equal 'NASB1995', T.gateway_code('NASB95')
  end

  def test_the_others_map_to_themselves
    assert_equal 'NKJV', T.gateway_code('NKJV')
    assert_equal 'ESV',  T.gateway_code('ESV')
    assert_equal 'LSB',  T.gateway_code('LSB')
  end

  def test_original_languages_are_valid_options
    assert T.valid?('heb/grk')
    assert_equal 'Hebrew and Greek', T.label('HEB/GRK')
    assert T.valid?('allgrk')
    assert_equal 'LXX Old Testament and Greek New Testament', T.label('ALLGRK')
    assert_equal 'ALLGRK — LXX OT and Greek NT', T.options.last.first
  end

  def test_codes_are_case_and_whitespace_insensitive
    assert T.valid?('nasb95')
    assert T.valid?(' esv ')
    assert_equal 'NASB1995', T.gateway_code(' nasb95 ')
  end

  def test_unknown_translations_are_refused
    refute T.valid?('NIV')
    refute T.valid?('')
    refute T.valid?(nil)
  end

  def test_the_offered_list_can_be_narrowed
    Bible270.config.bible_versions = %w[ESV LSB]
    assert_equal %w[ESV LSB], T.codes
    refute T.valid?('NKJV')
  end

  def test_a_narrowed_list_ignores_codes_we_do_not_know
    Bible270.config.bible_versions = %w[ESV NIV]
    assert_equal %w[ESV], T.codes
  end

  def test_an_empty_list_falls_back_to_all_of_them
    Bible270.config.bible_versions = []
    assert_equal T::VERSIONS.keys, T.codes
  end

  def test_resolve_prefers_the_readers_choice
    assert_equal 'LSB', T.resolve('lsb')
  end

  def test_resolve_falls_back_to_the_site_default
    Bible270.config.bible_version = 'ESV'
    assert_equal 'ESV', T.resolve(nil)
    assert_equal 'ESV', T.resolve('NIV')
  end

  def test_resolve_never_returns_something_unusable
    Bible270.config.bible_versions = %w[LSB]
    Bible270.config.bible_version = 'NIV'
    assert_equal 'LSB', T.resolve(nil), 'should fall through to an offered code'
  end

  def test_labels_and_options
    assert_equal 'Legacy Standard Bible', T.label('LSB')
    assert_nil T.label('NIV')
    assert_equal [["NKJV — #{T.short_label('NKJV')}", 'NKJV']], T.options.first(1)
    assert_equal T::VERSIONS['NASB95'][:short], T.short_label('NASB95')
    assert_equal 'New American Standard Bible 1995', T.label('NASB95'), 'the full name is still available'
  end

  # "NASB95 — New American Standard Bible 1995" overflowed the select box.
  def test_select_options_stay_short_enough_for_the_box
    longest = T.options.map(&:first).max_by(&:length)
    assert longest.length <= 40, "option too long for the select: #{longest.inspect}"
  end

  def test_other_translations_can_link_to_blue_letter_bible
    {
      'NKJV' => 'nkjv', 'NASB95' => 'nasb95', 'LSB' => 'lsb', 'ESV' => 'esv', 'KJV' => 'kjv', 'YLT' => 'ylt'
    }.each do |version, reader|
      assert_equal "https://www.blueletterbible.org/#{reader}/gen/1/1/s_1001",
                   T.passage_url('Genesis 1', version, blue_letter: true)
    end
  end

  def test_other_translations_can_link_to_bible_com
    {
      'NKJV' => '114/GEN.1.NKJV', 'NASB95' => '100/GEN.1.NASB1995',
      'LSB' => '3345/GEN.1.LSB', 'ESV' => '59/GEN.1.ESV',
      'KJV' => '1/GEN.1.KJV', 'YLT' => '821/GEN.1.YLT98'
    }.each do |version, path|
      assert_equal "https://www.bible.com/bible/#{path}",
                   T.passage_url('Genesis 1', version, bible_com: true)
    end
  end

  def test_original_languages_can_link_to_bible_com
    assert_equal 'https://www.bible.com/bible/3585/GEN.1.WLC',
                 T.passage_url("Genesis 1\u20133", 'HEB/GRK', bible_com: true)
    assert_equal 'https://www.bible.com/bible/3585/PSA.119.WLC',
                 T.passage_url("Psalm 119:17\u201332", 'HEB/GRK', bible_com: true)
    assert_equal 'https://www.bible.com/bible/2270/MAT.21.THGNT',
                 T.passage_url('Matthew 21', 'HEB/GRK', bible_com: true)
  end

  def test_all_greek_links_to_mgnt_on_blue_letter_bible
    assert_equal 'https://www.blueletterbible.org/mgnt/gen/1/1/s_1001',
                 T.passage_url('Genesis 1', 'ALLGRK')
    assert_equal 'https://www.blueletterbible.org/mgnt/mat/1/1/s_930001',
                 T.passage_url('Matthew 1', 'ALLGRK', blue_letter: true)
  end

  def test_all_greek_links_to_grcbrent_and_thgnt_on_bible_com
    assert_equal 'https://www.bible.com/bible/2503/GEN.1.GRCBRENT',
                 T.passage_url('Genesis 1', 'ALLGRK', bible_com: true)
    assert_equal 'https://www.bible.com/bible/2270/MAT.1.THGNT',
                 T.passage_url('Matthew 1', 'ALLGRK', bible_com: true)
  end

  def test_an_unrecognised_reference_links_to_bible_coms_reader
    assert_equal 'https://www.bible.com/bible',
                 T.passage_url('Unknown 1', 'KJV', bible_com: true)
  end

  def test_unflagged_translation_urls_use_bible_gateway
    url = T.passage_url('Genesis 1', 'KJV')

    assert_includes url, 'biblegateway.com'
    assert_includes url, 'version=KJV'
  end

  def test_bible_gateway_escapes_references
    url = T.passage_url("Genesis 1\u20133", 'NKJV')
    assert_equal 'https://www.biblegateway.com/passage/?search=Genesis+1%E2%80%933&version=NKJV', url
  end

  def test_bible_gateway_escapes_multi_book_references
    url = T.passage_url("Zechariah 14, Malachi 1\u20134", 'KJV')
    assert_includes url, 'search=Zechariah+14%2C+Malachi+1%E2%80%934'
    assert_includes url, 'version=KJV'
  end

  def test_split_chapter_reference_round_trips
    url = T.passage_url("Psalm 119:1\u201388", 'NKJV')
    assert_includes url, 'Psalm+119%3A1%E2%80%9388'
  end

  def test_original_language_ot_links_to_wlc
    assert_equal 'https://www.blueletterbible.org/wlc/gen/1/1/s_1001',
                 T.passage_url("Genesis 1\u20133", 'HEB/GRK')
  end

  def test_original_language_psalms_and_proverbs_link_to_wlc
    assert_equal 'https://www.blueletterbible.org/wlc/psa/1/1/s_479001',
                 T.passage_url('Psalm 1', 'HEB/GRK')
    assert_equal 'https://www.blueletterbible.org/wlc/pro/31/10/s_659010',
                 T.passage_url("Proverbs 31:10\u201331", 'HEB/GRK')
  end

  def test_original_language_nt_links_to_mgnt
    assert_equal 'https://www.blueletterbible.org/mgnt/mat/1/1/s_930001',
                 T.passage_url('Matthew 1', 'HEB/GRK')
  end

  def test_original_language_split_readings_start_at_the_first_verse
    assert_equal 'https://www.blueletterbible.org/wlc/psa/119/17/s_597017',
                 T.passage_url("Psalm 119:17\u201332", 'HEB/GRK')
  end

  def test_an_unrecognised_original_language_reference_links_to_blb
    assert_equal 'https://www.blueletterbible.org/', T.passage_url('Unknown 1', 'HEB/GRK')
  end
end
