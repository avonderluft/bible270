# frozen_string_literal: true

require 'test_helper'

class PlanTest < Minitest::Test
  P = Bible270::Plan

  def test_totals
    assert_equal 748,   P.totals[:ot]          # OT chapters (excl. Ps/Prov)
    assert_equal 260,   P.totals[:nt]          # NT chapters, read once
    assert_equal 1,     P.totals[:nt_passes]
    assert_equal 270,   P.totals[:nt_readings]
    assert_equal P.divided_nt_chapters.size, P.totals[:nt_divided]
    assert_equal 150, P.totals[:psalms]
    assert_equal P.psalm_readings.size, P.totals[:psalm_readings]
    assert_equal 31, P.totals[:proverbs]
    assert_equal P.proverbs_readings.size, P.totals[:proverbs_readings]
    assert_equal 25,    P.totals[:psalms_whole_max_verses]
    assert_equal 181,   P.totals[:pp]
    assert_equal 3376,  P.totals[:pp_verses]
    assert_equal 19_771, P.totals[:ot_verses]
    assert_equal 270, P.totals[:days]
  end

  def test_day_one_opens_all_three_tracks
    r = P.readings_for(1)
    assert_equal "Genesis 1\u20133", r['ot']
    assert r['nt'].start_with?('Matthew 1'), "NT should open at Matthew 1, got #{r['nt']}"
    assert r['pp'].start_with?('Psalm 1'),   "PsPr should open at Psalm 1, got #{r['pp']}"
  end

  def test_final_day_closes_every_track
    r = P.readings_for(P::DAYS)
    assert_includes r['ot'], 'Malachi'
    assert_equal 'Revelation 22', r['nt']
    assert r['pp'].start_with?('Proverbs 31'), "expected Proverbs 31, got #{r['pp']}"
    # Psalm 150 lands in the closing days too
    assert P.pp_plan.last(3).include?('Psalm 150'), 'Psalm 150 should finish near the end'
  end

  def test_ot_and_ps_prov_present_every_day
    (1..P::DAYS).each do |d|
      assert P.readings_for(d)['ot'], "day #{d} missing OT"
      assert P.readings_for(d)['pp'], "day #{d} missing Psalms/Proverbs"
    end
  end

  def test_all_three_tracks_present_every_day
    (1..P::DAYS).each do |d|
      assert_equal 3, P.required_track_count(d), "day #{d} is missing a track"
    end
  end

  # --- New Testament read once ------------------------------------------

  def test_new_testament_is_read_exactly_once_and_completely
    by_chapter = P.nt_readings.group_by { |s| [s[0], s[1]] }
    assert_equal 260, by_chapter.size, 'every NT chapter should appear'
    by_chapter.each do |(book, chapter), segments|
      total = Bible270::Versification.verses(book, chapter)
      if segments.size == 1
        assert_nil segments.first[2], "#{book} #{chapter} should be whole"
      else
        assert_equal (1..total).to_a, segments.flat_map { |s| (s[2]..s[3]).to_a },
                     "#{book} #{chapter} parts should cover it exactly once"
      end
    end
    assert_equal(P.totals[:nt_verses], P.nt_readings.sum { |s| P.segment_length(s) })
  end

  def test_nt_has_a_reading_every_day_with_no_days_off
    assert_equal P::DAYS, P.nt_readings.size
    assert_equal P::DAYS, P.nt_content_days
    assert_empty P.nt_rest_days
    (1..P::DAYS).each { |d| assert P.readings_for(d)['nt'], "day #{d} has no NT reading" }
  end

  def test_long_nt_chapters_are_divided_where_chapter_breaks_say
    divided = P.divided_nt_chapters
    refute_empty divided
    assert_includes divided.keys, ['Luke', 1]

    # Luke 1 is broken at the annunciations / Magnificat / Benedictus
    assert_equal([['Luke', 1, 1, 25], ['Luke', 1, 26, 56], ['Luke', 1, 57, 80]],
                 P.nt_readings.select { |seg| seg[0] == 'Luke' && seg[1] == 1 })
  end

  def test_dividing_brings_the_longest_nt_reading_down
    assert_equal 80, Bible270::Versification.verses('Luke', 1)
    assert P.nt_verse_loads.max < 80,
           'longest NT reading should be shorter than the longest chapter'
  end

  def test_nt_runs_matthew_to_revelation
    assert_equal 'Matthew 1', P.readings_for(1)['nt']
    assert_equal 'Revelation 22', P.readings_for(P::DAYS)['nt']
  end

  # --- Psalms once, Proverbs twice ---------------------------------------

  def test_psalm_119_is_eleven_sections_of_sixteen_verses
    parts = P.pp_readings.select { |s| s[0] == 'Psalm' && s[1] == 119 }
    assert_equal 11, parts.size
    parts.each { |s| assert_equal 16, s[3] - s[2] + 1, 'each section should be 16 verses' }
    assert_equal [1, 16],    [parts.first[2], parts.first[3]]
    assert_equal [161, 176], [parts.last[2],  parts.last[3]]
    # contiguous and complete, no gaps or overlaps
    assert_equal((1..176).to_a, parts.flat_map { |s| (s[2]..s[3]).to_a })
  end

  def test_every_psalm_is_read_exactly_once
    covered = P.psalm_readings.group_by { |s| s[1] }
    assert_equal 150, covered.size, 'all 150 psalms should appear'
    covered.each do |chapter, segments|
      total = Bible270::Versification.verses('Psalm', chapter)
      if segments.size == 1
        assert_nil segments.first[2], "Psalm #{chapter} should be a whole chapter"
      else
        verses = segments.flat_map { |s| (s[2]..s[3]).to_a }
        assert_equal (1..total).to_a, verses,
                     "Psalm #{chapter} parts should cover it exactly once"
      end
    end
  end

  def test_proverbs_is_read_exactly_once_and_completely
    by_chapter = P.pp_readings.select { |seg| seg[0] == 'Proverbs' }.group_by { |seg| seg[1] }
    assert_equal 31, by_chapter.size

    by_chapter.each do |chapter, segments|
      total = Bible270::Versification.verses('Proverbs', chapter)
      next assert_nil(segments.first[2]) if segments.size == 1

      assert_equal (1..total).to_a, segments.flat_map { |seg| (seg[2]..seg[3]).to_a },
                   "Proverbs #{chapter} should be covered exactly once"
    end
  end

  def test_psalms_of_25_verses_or_fewer_are_never_divided
    P.divided_psalms.each_key do |chapter|
      verses = Bible270::Versification.verses('Psalm', chapter)
      assert_operator verses, :>, P::PSALM_WHOLE_MAX_VERSES,
                      "Psalm #{chapter} has #{verses} verses and should stay whole"
    end
  end

  def test_a_divided_chapter_is_read_on_consecutive_days
    blocks = P.pp_readings.chunk_while { |a, b| a[0] == b[0] && a[1] == b[1] }
      .map { |group| [group.first[0], group.first[1]] }
    assert_equal blocks.uniq.size, blocks.size,
                 'no chapter may appear in more than one run of days'
  end

  def test_nothing_is_inserted_between_the_parts_of_a_split_psalm
    P.divided_psalms.each_key do |chapter|
      days = (1..P::DAYS).select do |d|
        seg = P.pp_readings[d - 1]
        seg[0] == 'Psalm' && seg[1] == chapter
      end
      assert_equal days.last - days.first + 1, days.size,
                   "Psalm #{chapter} is interrupted: days #{days.inspect}"
    end
  end

  def test_proverbs_is_spread_throughout_the_plan
    days = P.proverbs_days
    assert_equal 31, P.pp_readings.select { |seg| seg[0] == 'Proverbs' }.group_by { |s| s[1] }.size
    gaps = ([0] + days + [P::DAYS + 1]).each_cons(2).map { |a, b| b - a }
    assert gaps.max <= 20, "Proverbs should never be absent for long, biggest gap #{gaps.max}"
  end

  def test_psalms_and_proverbs_exactly_fill_the_plan
    assert_equal P::DAYS, P.psalm_readings.size + P.proverbs_readings.size
    assert_equal P::DAYS, P.pp_readings.size
    assert_equal(2461, P.psalm_readings.sum { |seg| P.segment_length(seg) })
    assert_equal(915,  P.proverbs_readings.sum { |seg| P.segment_length(seg) })
  end

  def test_no_psalm_reading_runs_long
    # The ceiling is set by CHAPTER_BREAKS: Psalm 78 is deliberately broken once,
    # at verse 39, so its halves are the longest readings in the track.
    lengths = P.psalm_readings.map { |seg| P.segment_length(seg) }
    assert lengths.max <= 40, "longest psalm reading is #{lengths.max} verses"
  end

  def test_ot_chapters_are_never_split
    # OT portions are always whole chapters, so no reference carries a verse colon
    (1..P::DAYS).each do |d|
      refute_includes P.readings_for(d)['ot'], ':', "day #{d} OT reference splits a chapter"
    end
  end

  def test_ot_chapters_are_never_divided
    (1..P::DAYS).each do |d|
      refute_includes P.readings_for(d)['ot'], ':', "day #{d} OT reference divides a chapter"
    end
  end

  # --- rough balance by actual text length -------------------------------

  def test_daily_portions_are_roughly_equal_by_verses
    [['OT', P.ot_verse_loads], ['NT', P.nt_verse_loads], ['PsPr', P.pp_verse_loads]].each do |name, loads|
      assert_equal P::DAYS, loads.size
      ratio = loads.max.to_f / loads.min
      assert ratio < 20.0, "#{name} spread too wide: #{loads.min}..#{loads.max}"
    end
  end

  def test_no_track_ever_has_an_empty_day
    [P.ot_verse_loads, P.nt_verse_loads, P.pp_verse_loads].each do |loads|
      assert_equal 0, loads.count(&:zero?)
    end
  end

  def test_total_daily_load_is_stable
    totals = (0...P::DAYS).map { |i| P.ot_verse_loads[i] + P.nt_verse_loads[i] + P.pp_verse_loads[i] }
    avg = totals.sum.to_f / totals.size
    # no day should be wildly heavier or lighter than the average day
    assert totals.max < avg * 1.75, "heaviest day #{totals.max} vs avg #{avg.round}"
    assert totals.min > avg * 0.55, "lightest day #{totals.min} vs avg #{avg.round}"
  end

  def test_long_psalm_outweighs_short_psalm
    days_119 = (1..P::DAYS).count { |d| P.readings_for(d)['pp'].include?('Psalm 119') }
    days_117 = (1..P::DAYS).count { |d| P.readings_for(d)['pp'].include?('Psalm 117') }
    assert_equal 11, days_119
    assert_equal 1, days_117
  end

  # --- reference formatting ---------------------------------------------

  def test_reference_collapses_consecutive_chapters
    assert_equal "Genesis 1\u20133",
                 P.format_reference([['Genesis', 1], ['Genesis', 2], ['Genesis', 3]])
    assert_equal 'Malachi 4, Matthew 1',
                 P.format_reference([['Malachi', 4], ['Matthew', 1]])
  end

  def test_segment_formatting
    assert_equal 'Psalm 23',           P.format_segment(['Psalm', 23])
    assert_equal 'Proverbs 31',        P.format_segment(['Proverbs', 31])
    assert_equal "Psalm 119:1\u201316", P.format_segment(['Psalm', 119, 1, 16])
    assert_equal 'Psalm 9:5', P.format_segment(['Psalm', 9, 5, 5])
    assert_equal "Luke 1:41\u201380", P.format_segment(['Luke', 1, 41, 80])
  end

  def test_valid_day_bounds
    refute P.valid_day?(0)
    refute P.valid_day?(271)
    assert P.valid_day?(1)
    assert P.valid_day?(270)
  end
end

class CalendarTest < Minitest::Test
  P = Bible270::Plan
  START = Date.new(2026, 9, 6) # a Sunday

  def test_to_date_coercion
    assert_equal START, P.to_date(START)
    assert_equal START, P.to_date('2026-09-06')
    assert_equal START, P.to_date(Time.new(2026, 9, 6, 13, 30))
    assert_nil P.to_date(nil)
    assert_nil P.to_date('not a date')
  end

  def test_date_for_day
    assert_equal START,                    P.date_for(1, START)
    assert_equal Date.new(2026, 9, 7),     P.date_for(2, START)
    assert_equal START + 269,              P.date_for(270, START)
    assert_nil P.date_for(1, nil)      # undated plan
    assert_nil P.date_for(0, START)    # out of range
    assert_nil P.date_for(271, START)
  end

  def test_end_date_is_269_days_after_start
    assert_equal START + 269, P.end_date_for(START)
    assert_equal Date.new(2027, 6, 2), P.end_date_for(START)
    assert_nil P.end_date_for(nil)
  end

  def test_day_for_date_is_the_inverse_of_date_for
    (1..P::DAYS).each do |d|
      assert_equal d, P.day_for(P.date_for(d, START), START), "day #{d} did not round-trip"
    end
  end

  def test_day_for_clamps_by_default
    assert_equal 1,   P.day_for(START - 10, START)
    assert_equal 270, P.day_for(START + 500, START)
    assert_nil P.day_for(Date.today, nil)
  end

  def test_day_for_unclamped_reveals_out_of_range
    assert_equal(-9, P.day_for(START - 10, START, clamp: false))
    assert_equal 271, P.day_for(START + 270, START, clamp: false)
  end

  def test_before_start_and_after_end
    assert P.before_start?(START - 1, START)
    refute P.before_start?(START, START)
    refute P.after_end?(P.end_date_for(START), START)
    assert P.after_end?(P.end_date_for(START) + 1, START)
    # an undated plan is never "before" or "after"
    refute P.before_start?(Date.today, nil)
    refute P.after_end?(Date.today, nil)
  end

  def test_leap_day_is_handled
    start = Date.new(2028, 1, 1) # 2028 is a leap year
    assert_equal Date.new(2028, 2, 29), P.date_for(60, start)
    assert_equal 60, P.day_for(Date.new(2028, 2, 29), start)
  end

  def test_string_start_dates_work_end_to_end
    assert_equal Date.new(2026, 9, 6), P.date_for(1, '2026-09-06')
    assert_equal 2, P.day_for('2026-09-07', '2026-09-06')
  end
end

# Break points from the host app: config, and a YAML file re-read when it changes.
class ChapterBreakSourcesTest < Minitest::Test
  P = Bible270::Plan

  def setup
    require 'bible270/configuration'
    require 'tempfile'
    @breaks = Bible270.config.chapter_breaks
    @path   = Bible270.config.chapter_breaks_path
    Bible270.config.chapter_breaks = {}
    Bible270.config.chapter_breaks_path = nil
    P.reset!
  end

  def teardown
    Bible270.config.chapter_breaks = @breaks
    Bible270.config.chapter_breaks_path = @path
    P.reset!
  end

  def psalm78 = P.pp_readings.select { |seg| seg[0] == 'Psalm' && seg[1] == 78 }

  def test_the_constant_applies_by_default
    assert_equal 4, psalm78.size, 'CHAPTER_BREAKS divides Psalm 78 four ways'
  end

  def test_config_overrides_the_constant_with_either_key_style
    Bible270.config.chapter_breaks = { 'Psalm 78' => [] }
    assert_equal [['Psalm', 78]], psalm78

    Bible270.config.chapter_breaks = { ['Psalm', 78] => [36] }
    assert_equal 2, psalm78.size
  end

  def test_a_file_wins_and_is_re_read_when_it_changes
    file = Tempfile.new(['breaks', '.yml'])
    Bible270.config.chapter_breaks_path = file.path

    File.write(file.path, "Psalm 78: [36]\n")
    assert_equal 2, psalm78.size

    sleep 0.01
    File.write(file.path, "Psalm 78: []\n")
    assert_equal [['Psalm', 78]], psalm78, 'an edited file should be picked up with no reset'

    File.write(file.path, "{}\n")
    assert_equal 4, psalm78.size, 'emptying the file falls back to the constant'
  ensure
    file&.close
    file&.unlink
  end

  def test_the_plan_still_fills_270_days_whatever_the_source
    Bible270.config.chapter_breaks = { 'Psalm 78' => [], 'Psalm 119' => [], 'Proverbs 3' => [17] }
    assert_equal P::DAYS, P.pp_readings.size
    assert_equal(2461, P.psalm_readings.sum { |seg| P.segment_length(seg) })
    assert_equal(915,  P.proverbs_readings.sum { |seg| P.segment_length(seg) })
  end

  def test_a_malformed_key_is_rejected
    Bible270.config.chapter_breaks = { 'Psalm' => [] }
    assert_match(%r{must look like}, assert_raises(ArgumentError) { P.pp_readings }.message)
  end
end
