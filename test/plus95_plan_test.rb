# frozen_string_literal: true

require 'minitest/autorun'
require 'bible270/configuration'
require 'bible270/plan'
require 'bible270/translations'

class Plus95PlanTest < Minitest::Test
  PLAN = Bible270::Plan
  VERSES = Bible270::Versification::VERSES
  TRANSLATIONS = Bible270::Translations
  START = Date.new(2024, 1, 1)
  EXTENSION = (271..365)
  REFERENCE = %r{\A(.+) (\d+)(?::(\d+)–(\d+))?\z}

  def test_extension_reads_each_stream_in_order_without_skipping_or_repeating_verses
    nt_books = VERSES.keys.drop_while { |book| book != 'Matthew' }
    assert_equal canonical_verses(nt_books), assigned_verses(references('nt'))

    wisdom = references('pp')
    psalms = canonical_verses(['Psalm']).drop(VERSES.fetch('Psalm').first)
    assert_equal psalms, assigned_verses(wisdom.grep(%r{\APsalm }))
    assert_equal canonical_verses(['Proverbs']), assigned_verses(wisdom.grep(%r{\AProverbs }))
  end

  def test_wisdom_is_interleaved_and_psalm_119_splits_only_between_stanzas
    wisdom = references('pp')
    proverbs_days = EXTENSION.select { |day| PLAN.parts_for(day, 'pp').any? { |ref| ref.start_with?('Proverbs ') } }
    assert_equal 31, proverbs_days.size
    assert_operator proverbs_days.first, :<=, 275
    assert_equal 365, proverbs_days.last
    # The longest gap is the uninterrupted reading of Psalm 119.
    assert_operator proverbs_days.each_cons(2).map { |a, b| b - a }.max, :<=, 8

    assert_empty references('nt').grep(%r{:}), 'Keep the NT chapters whole'
    slices = wisdom.grep(%r{:})
    assert_operator slices.size, :>, 1
    slices.each do |reference|
      book, chapter, verses = parse(reference)
      assert_equal ['Psalm', 119], [book, chapter], reference
      assert_equal 0, (verses.begin - 1) % 8, reference
      assert_equal 0, verses.end % 8, reference
    end
  end

  def test_every_extension_day_has_two_tracks_and_a_balanced_load
    assert_equal [270, 95, 365], [PLAN::DAYS, PLAN::PLUS95_DAYS, PLAN::EXTENDED_DAYS]
    assert_equal PLAN::PLUS95_DAYS, EXTENSION.map { |day| PLAN.readings_for(day) }.uniq.size
    loads = EXTENSION.map do |day|
      assert_equal %w[nt pp], PLAN.present_tracks(day), "day #{day}"
      assert_nil PLAN.readings_for(day)['ot']
      assert_empty PLAN.parts_for(day, 'ot')
      assert_equal 2, PLAN.required_track_count(day)
      parts = %w[nt pp].flat_map { |track| PLAN.parts_for(day, track) }
      assert_equal parts.size, PLAN.total_parts(day)
      parts.sum { |ref| parse(ref).last.size }
    end

    assert_operator loads.min, :>=, 109
    assert_operator loads.max, :<=, 131
    assert_in_delta 119, loads.sum.fdiv(loads.size), 1
  end

  def test_calendar_boundary_and_ending_references
    assert_equal 'Revelation 22', PLAN.readings_for(270)['nt']
    assert_equal 'Psalm 1', PLAN.readings_for(270)['pp']
    assert_equal({ 'ot' => nil, 'nt' => 'Matthew 1–4', 'pp' => 'Psalm 2–3' }, PLAN.readings_for(271))
    assert_equal ['Psalm 2', 'Psalm 3'], PLAN.parts_for(271, 'pp')
    assert_equal ['Matthew 1', 'Matthew 2', 'Matthew 3', 'Matthew 4'], PLAN.parts_for(271, :nt)
    assert_equal ['Matthew 5', 'Matthew 6', 'Matthew 7'], PLAN.parts_for(272, 'nt')
    assert_equal 'Revelation 19–22', PLAN.readings_for(365)['nt']
    assert_equal 'Revelation 22', PLAN.parts_for(365, 'nt').last
    assert_equal 'Psalm 150; Proverbs 31', PLAN.readings_for(365)['pp']
    assert_equal ['Psalm 150', 'Proverbs 31'], PLAN.parts_for(365, 'pp')
  end

  def test_each_part_is_checkable_and_links_to_its_own_passage
    EXTENSION.each do |day|
      %w[nt pp].each do |track|
        parts = PLAN.parts_for(day, track)
        parts.each_with_index do |reference, index|
          assert PLAN.valid_part?(day, track, index), [day, track, index].inspect
          book, chapter, verses = parse(reference)
          assert_equal [VERSES.keys.index(book), chapter, verses.begin], TRANSLATIONS.reference_start(reference)
        end
        refute PLAN.valid_part?(day, track, parts.size)
        refute PLAN.valid_part?(day, track, -1)
      end
    end

    proverb = PLAN.parts_for(365, 'pp').last
    assert_equal 'https://www.biblegateway.com/passage/?search=Proverbs+31&version=NKJV', TRANSLATIONS.passage_url(proverb, 'NKJV')
    assert_equal 'https://www.bible.com/bible/114/PRO.31.NKJV', TRANSLATIONS.passage_url(proverb, 'NKJV', bible_com: true)
    assert_equal 'https://www.blueletterbible.org/wlc/pro/31/1/s_659001', TRANSLATIONS.passage_url(proverb, 'HEB/GRK')
  end

  def test_invalid_days_and_parts_do_not_wrap_or_coerce
    [nil, -1, 0, 366, '271', 271.0].each do |day|
      refute PLAN.valid_day?(day, days: PLAN::EXTENDED_DAYS)
      assert_nil PLAN.readings_for(day)
      assert_empty PLAN.present_tracks(day)
      assert_empty PLAN.parts_for(day, 'nt')
      refute PLAN.valid_part?(day, 'nt', 0)
      assert_equal 0, PLAN.total_parts(day)
    end
    refute PLAN.valid_part?(271, 'ot', 0)
    refute PLAN.valid_part?(271, 'nt', '0')
    assert_empty PLAN.parts_for(271, 'unknown')
  end

  def test_calendar_scope_defaults_to_270_but_can_extend_to_365
    days = PLAN::EXTENDED_DAYS
    refute PLAN.valid_day?(271)
    assert PLAN.valid_day?(271, days: days)
    assert PLAN.valid_day?(365, days: days)
    assert_nil PLAN.date_for(271, START)
    assert_equal START + 270, PLAN.date_for(271, START, days: days)
    assert_equal START + 269, PLAN.end_date_for(START)
    assert_equal START + 364, PLAN.end_date_for(START, days: days)
    assert_equal START + 364, PLAN.date_for(365, START.iso8601, days: days)
    assert_nil PLAN.date_for(366, START, days: days)
    assert_nil PLAN.end_date_for(nil, days: days)
    assert_equal 270, PLAN.day_for(START + 364, START)
    assert_equal 271, PLAN.day_for(START + 270, START, days: days)
    assert_equal 365, PLAN.day_for(START + 365, START, days: days)
    assert_equal 366, PLAN.day_for(START + 365, START, clamp: false, days: days)
    assert_equal 1, PLAN.day_for(START - 1, START, days: days)
    assert_nil PLAN.day_for(START, nil, days: days)
    assert PLAN.after_end?(START + 270, START)
    refute PLAN.after_end?(START + 364, START, days: days)
    assert PLAN.after_end?(START + 365, START, days: days)
    refute PLAN.after_end?(START, nil, days: days)
  end

  def test_track_day_totals_match_the_calendar_for_both_lengths
    assert_equal([270, 270, 270], %w[ot nt pp].map { |track| PLAN.track_days(track) })
    assert_equal([270, 365, 365], %i[ot nt pp].map { |track| PLAN.track_days(track, days: PLAN::EXTENDED_DAYS) })
    assert_equal 0, PLAN.track_days(:unknown, days: PLAN::EXTENDED_DAYS)
  end

  def test_plus95_is_not_redivided_by_configured_chapter_breaks
    config = Bible270.config
    saved_breaks = config.chapter_breaks
    saved_path = config.chapter_breaks_path
    config.chapter_breaks_path = nil
    config.chapter_breaks = {}
    initial_nt = PLAN.nt_plan.dup
    initial_plus95 = extension_snapshot

    config.chapter_breaks['Matthew 26'] = [24]
    config.chapter_breaks['Psalm 119'] = [25, 72, 168]
    PLAN.reset!

    refute_equal initial_nt, PLAN.nt_plan
    assert_equal initial_plus95, extension_snapshot
  ensure
    config.chapter_breaks = saved_breaks
    config.chapter_breaks_path = saved_path
    PLAN.reset!
  end

private

  def extension_snapshot
    EXTENSION.map { |day| [PLAN.readings_for(day), PLAN.parts_for(day, 'nt'), PLAN.parts_for(day, 'pp')] }
  end

  def references(track)
    EXTENSION.flat_map { |day| PLAN.parts_for(day, track) }
  end

  def parse(reference)
    match = REFERENCE.match(reference)
    assert match, "Expected a single passage, got #{reference.inspect}"
    book, chapter, first, last = match.captures
    chapter = Integer(chapter)
    length = VERSES.fetch(book).fetch(chapter - 1)
    first = first ? Integer(first) : 1
    last = last ? Integer(last) : length
    assert chapter.positive? && first.between?(1, last) && last <= length, reference
    [book, chapter, first..last]
  end

  def assigned_verses(refs)
    refs.flat_map do |ref|
      book, chapter, verses = parse(ref)
      verses.map { |verse| [book, chapter, verse] }
    end
  end

  def canonical_verses(books)
    books.flat_map do |book|
      VERSES.fetch(book).each_with_index.flat_map do |length, index|
        (1..length).map { |verse| [book, index + 1, verse] }
      end
    end
  end
end
