# frozen_string_literal: true
require "test_helper"

class PlanTest < Minitest::Test
  P = Bible270::Plan

  def test_totals
    assert_equal 748,   P.totals[:ot]          # OT chapters (excl. Ps/Prov)
    assert_equal 260,   P.totals[:nt]          # NT chapters, read once
    assert_equal 1,     P.totals[:nt_passes]
    assert_equal 270,   P.totals[:nt_readings]
    assert_equal 10,    P.totals[:nt_divided]
    assert_equal 150,   P.totals[:psalms]
    assert_equal 208,   P.totals[:psalm_readings]
    assert_equal 31,    P.totals[:proverbs]
    assert_equal 2,     P.totals[:proverbs_passes]
    assert_equal 62,    P.totals[:proverbs_readings]
    assert_equal 181,   P.totals[:pp]
    assert_equal 3376,  P.totals[:pp_verses]
    assert_equal 19771, P.totals[:ot_verses]
    assert_equal 270,   P.totals[:days]
  end

  def test_day_one_opens_all_three_tracks
    r = P.readings_for(1)
    assert_equal "Genesis 1\u20133", r["ot"]
    assert r["nt"].start_with?("Matthew 1"), "NT should open at Matthew 1, got #{r['nt']}"
    assert r["pp"].start_with?("Psalm 1"),   "PsPr should open at Psalm 1, got #{r['pp']}"
  end

  def test_final_day_closes_every_track
    r = P.readings_for(P::DAYS)
    assert_includes r["ot"], "Malachi"
    assert_equal "Revelation 22", r["nt"]
    assert_equal "Proverbs 31", r["pp"]
    # Psalm 150 lands in the closing days too
    assert P.pp_plan.last(3).include?("Psalm 150"), "Psalm 150 should finish near the end"
  end

  def test_ot_and_ps_prov_present_every_day
    (1..P::DAYS).each do |d|
      assert P.readings_for(d)["ot"], "day #{d} missing OT"
      assert P.readings_for(d)["pp"], "day #{d} missing Psalms/Proverbs"
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
    assert_equal 260, by_chapter.size, "every NT chapter should appear"
    by_chapter.each do |(book, chapter), segments|
      total = Bible270::Versification.verses(book, chapter)
      if segments.size == 1
        assert_nil segments.first[2], "#{book} #{chapter} should be whole"
      else
        assert_equal (1..total).to_a, segments.flat_map { |s| (s[2]..s[3]).to_a },
                     "#{book} #{chapter} parts should cover it exactly once"
      end
    end
    assert_equal P.totals[:nt_verses], P.nt_readings.sum { |s| P.segment_length(s) }
  end

  def test_nt_has_a_reading_every_day_with_no_days_off
    assert_equal P::DAYS, P.nt_readings.size
    assert_equal P::DAYS, P.nt_content_days
    assert_empty P.nt_rest_days
    (1..P::DAYS).each { |d| assert P.readings_for(d)["nt"], "day #{d} has no NT reading" }
  end

  def test_the_ten_longest_nt_chapters_are_halved
    divided = P.divided_nt_chapters
    assert_equal 10, divided.size
    assert_equal [2], divided.values.uniq, "each divided chapter becomes two readings"
    assert_includes divided.keys, ["Luke", 1]
    # Luke 1 (80 verses) splits evenly
    luke1 = P.nt_readings.select { |s| s[0] == "Luke" && s[1] == 1 }
    assert_equal [["Luke", 1, 1, 40], ["Luke", 1, 41, 80]], luke1
  end

  def test_dividing_brings_the_longest_nt_reading_down
    assert_equal 80, Bible270::Versification.verses("Luke", 1)
    assert P.nt_verse_loads.max < 80,
           "longest NT reading should be shorter than the longest chapter"
    assert_equal 58, P.nt_verse_loads.max
  end

  def test_nt_runs_matthew_to_revelation
    assert_equal "Matthew 1", P.readings_for(1)["nt"]
    assert_equal "Revelation 22", P.readings_for(P::DAYS)["nt"]
  end

  # --- Psalms once, Proverbs twice ---------------------------------------

  def test_psalm_119_is_eleven_sections_of_sixteen_verses
    parts = P.pp_readings.select { |s| s[0] == "Psalm" && s[1] == 119 }
    assert_equal 11, parts.size
    parts.each { |s| assert_equal 16, s[3] - s[2] + 1, "each section should be 16 verses" }
    assert_equal [1, 16],    [parts.first[2], parts.first[3]]
    assert_equal [161, 176], [parts.last[2],  parts.last[3]]
    # contiguous and complete, no gaps or overlaps
    assert_equal (1..176).to_a, parts.flat_map { |s| (s[2]..s[3]).to_a }
  end

  def test_every_psalm_is_read_exactly_once
    covered = P.psalm_readings.group_by { |s| s[1] }
    assert_equal 150, covered.size, "all 150 psalms should appear"
    covered.each do |chapter, segments|
      total = Bible270::Versification.verses("Psalm", chapter)
      if segments.size == 1
        assert_nil segments.first[2], "Psalm #{chapter} should be a whole chapter"
      else
        verses = segments.flat_map { |s| (s[2]..s[3]).to_a }
        assert_equal (1..total).to_a, verses,
                     "Psalm #{chapter} parts should cover it exactly once"
      end
    end
  end

  def test_proverbs_is_read_twice_in_whole_chapters
    prov = P.pp_readings.select { |s| s[0] == "Proverbs" }
    assert_equal 62, prov.size
    assert_equal [2], prov.group_by { |s| s[1] }.values.map(&:size).uniq,
                 "every Proverbs chapter should appear twice"
    prov.each { |s| assert_nil s[2], "Proverbs chapters should never be divided" }
  end

  def test_proverbs_readings_are_evenly_spaced
    gaps = P.proverbs_days.each_cons(2).map { |a, b| b - a }.uniq.sort
    assert gaps.max - gaps.min <= 1, "Proverbs days should be evenly spaced, got gaps #{gaps.inspect}"
  end

  def test_each_proverbs_pass_ends_on_a_landmark_day
    assert_equal [135, 270], (1..P::DAYS).select { |d| P.readings_for(d)["pp"] == "Proverbs 31" }
  end

  def test_psalms_and_proverbs_exactly_fill_the_plan
    assert_equal 208, P.psalm_readings.size
    assert_equal 62,  P.proverbs_reading_count
    assert_equal P::DAYS, P.psalm_readings.size + P.proverbs_reading_count
    assert_equal P::DAYS, P.pp_readings.size
  end

  def test_no_psalm_reading_runs_long
    lengths = P.psalm_readings.map { |s| P.segment_length(s) }
    assert lengths.max <= 20, "longest psalm reading is #{lengths.max} verses"
  end

  def test_ot_chapters_are_never_split
    # OT portions are always whole chapters, so no reference carries a verse colon
    (1..P::DAYS).each do |d|
      refute_includes P.readings_for(d)["ot"], ":", "day #{d} OT reference splits a chapter"
    end
  end

  def test_ot_chapters_are_never_divided
    (1..P::DAYS).each do |d|
      refute_includes P.readings_for(d)["ot"], ":", "day #{d} OT reference divides a chapter"
    end
  end

  # --- rough balance by actual text length -------------------------------

  def test_daily_portions_are_roughly_equal_by_verses
    [["OT", P.ot_verse_loads], ["NT", P.nt_verse_loads], ["PsPr", P.pp_verse_loads]].each do |name, loads|
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
    days_119 = (1..P::DAYS).count { |d| P.readings_for(d)["pp"].include?("Psalm 119") }
    days_117 = (1..P::DAYS).count { |d| P.readings_for(d)["pp"].include?("Psalm 117") }
    assert_equal 11, days_119
    assert_equal 1, days_117
  end

  # --- reference formatting ---------------------------------------------

  def test_reference_collapses_consecutive_chapters
    assert_equal "Genesis 1\u20133",
                 P.format_reference([["Genesis", 1], ["Genesis", 2], ["Genesis", 3]])
    assert_equal "Malachi 4, Matthew 1",
                 P.format_reference([["Malachi", 4], ["Matthew", 1]])
  end

  def test_segment_formatting
    assert_equal "Psalm 23",           P.format_segment(["Psalm", 23])
    assert_equal "Proverbs 31",        P.format_segment(["Proverbs", 31])
    assert_equal "Psalm 119:1\u201316", P.format_segment(["Psalm", 119, 1, 16])
    assert_equal "Psalm 9:5",          P.format_segment(["Psalm", 9, 5, 5])
    assert_equal "Luke 1:41\u201380",   P.format_segment(["Luke", 1, 41, 80])
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
    assert_equal START, P.to_date("2026-09-06")
    assert_equal START, P.to_date(Time.new(2026, 9, 6, 13, 30))
    assert_nil P.to_date(nil)
    assert_nil P.to_date("not a date")
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
    assert_equal Date.new(2026, 9, 6), P.date_for(1, "2026-09-06")
    assert_equal 2, P.day_for("2026-09-07", "2026-09-06")
  end
end
