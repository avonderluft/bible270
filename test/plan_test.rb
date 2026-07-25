# frozen_string_literal: true
require "test_helper"

class PlanTest < Minitest::Test
  P = Bible270::Plan

  def test_totals
    assert_equal 748,   P.totals[:ot]          # OT chapters (excl. Ps/Prov)
    assert_equal 260,   P.totals[:nt]          # NT chapters per pass
    assert_equal 2,     P.totals[:nt_passes]
    assert_equal 520,   P.totals[:nt_chapters_read]
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
    assert_includes r["nt"], "Revelation"
    assert_includes r["pp"], "Proverbs 31"
  end

  def test_all_three_tracks_present_every_day
    (1..P::DAYS).each do |d|
      assert_equal 3, P.required_track_count(d), "day #{d} is missing a track"
    end
  end

  # --- New Testament read twice -----------------------------------------

  def test_new_testament_is_read_through_twice
    tally = P.nt_groups.flatten(1).tally
    assert_equal 260, tally.size, "every NT chapter should appear"
    assert_equal [2], tally.values.uniq, "every NT chapter should be read exactly twice"
  end

  def test_each_nt_pass_gets_half_the_plan
    assert_equal 135, P.nt_days_per_pass
    assert_equal 136, P.nt_second_pass_start_day
    # each pass ends with Revelation and the next begins with Matthew
    assert_includes P.readings_for(135)["nt"], "Revelation"
    assert P.readings_for(136)["nt"].start_with?("Matthew 1")
  end

  def test_nt_has_no_rest_days
    assert_equal P::DAYS, P.nt_content_days
  end

  # --- whole chapters, with one exception --------------------------------

  def test_only_psalm_119_is_split
    split = P.pp_base_portions.flatten(1).select { |s| s.size == 4 }
    assert_equal [["Psalm", 119]], split.map { |s| [s[0], s[1]] }.uniq,
                 "Psalm 119 should be the only split chapter"
  end

  def test_psalm_119_is_divided_into_two_readings
    parts = P.pp_base_portions.flatten(1).select { |s| s[0] == "Psalm" && s[1] == 119 }
    assert_equal 2, parts.size
    assert_equal [1, 88],   [parts[0][2], parts[0][3]]
    assert_equal [89, 176], [parts[1][2], parts[1][3]]
  end

  def test_psalms_78_and_89_are_never_split
    split = P.pp_base_portions.flatten(1).select { |s| s.size == 4 }
    [78, 89].each do |ch|
      refute split.any? { |s| s[0] == "Psalm" && s[1] == ch }, "Psalm #{ch} must stay whole"
    end
  end

  def test_ot_chapters_are_never_split
    # OT portions are always whole chapters, so no reference carries a verse colon
    (1..P::DAYS).each do |d|
      refute_includes P.readings_for(d)["ot"], ":", "day #{d} OT reference splits a chapter"
    end
  end

  def test_ps_prov_covers_every_chapter_and_cycles_evenly
    covered = P.pp_base_portions.flatten(1).map { |s| [s[0], s[1]] }.uniq
    assert_equal 181, covered.size
    # 135 base portions over 270 days = exactly two complete passes
    assert_equal 135, P.pp_cycle_length
    assert_equal 2, P::DAYS / P.pp_cycle_length
  end

  # --- rough balance by actual text length -------------------------------

  def test_daily_portions_are_roughly_equal_by_verses
    [["OT", P.ot_verse_loads], ["NT", P.nt_verse_loads], ["PsPr", P.pp_verse_loads]].each do |name, loads|
      assert_equal P::DAYS, loads.size
      assert (loads.max.to_f / loads.min) < 8.0, "#{name} spread too wide: #{loads.min}..#{loads.max}"
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
    assert days_119 > days_117, "Psalm 119 (176v) should occupy more days than Psalm 117 (2v)"
  end

  # --- reference formatting ---------------------------------------------

  def test_reference_collapses_consecutive_chapters
    assert_equal "Genesis 1\u20133",
                 P.format_reference([["Genesis", 1], ["Genesis", 2], ["Genesis", 3]])
    assert_equal "Malachi 4, Matthew 1",
                 P.format_reference([["Malachi", 4], ["Matthew", 1]])
  end

  def test_pp_formatting_of_whole_and_split_readings
    assert_equal "Psalm 23",          P.format_pp([["Psalm", 23]])
    assert_equal "Psalm 116\u2013117", P.format_pp([["Psalm", 116], ["Psalm", 117]])
    assert_equal "Psalm 119:1\u201388", P.format_pp([["Psalm", 119, 1, 88]])
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
