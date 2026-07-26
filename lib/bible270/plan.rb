# frozen_string_literal: true

require "date"
require "bible270/versification"

module Bible270
  # Pure-Ruby, deterministic reading-plan generator. No database required.
  #
  # Daily portions are balanced by VERSE COUNT (a canonical, translation-neutral
  # proxy for how much text there is), not by chapter count — so a day landing on
  # Psalm 119 (176 verses) is not treated as equal to a day on Psalm 117 (2 verses).
  #
  # * Old Testament   – read once (excluding Psalms and Proverbs); WHOLE chapters
  #                     grouped so each day is ~equal in verses (~73/day)
  # * New Testament   – read once, one reading every day; the 10 longest chapters
  #                     (Luke 1 and friends) are divided in two so 260 chapters fill 270 days
  # * Psalms/Proverbs – Psalms once and Proverbs TWICE, interleaved in one track.
  #                     Longer psalms are divided so the two fill exactly 270 days;
  #                     Psalm 119 is pinned to 11 sections of 16 verses.
  #
  # Genesis→Malachi, Revelation 22, Psalm 150 and the second Proverbs 31 all land
  # in the closing days.
  module Plan
    DAYS = 270

    OT = [
      ["Genesis", 50], ["Exodus", 40], ["Leviticus", 27], ["Numbers", 36],
      ["Deuteronomy", 34], ["Joshua", 24], ["Judges", 21], ["Ruth", 4],
      ["1 Samuel", 31], ["2 Samuel", 24], ["1 Kings", 22], ["2 Kings", 25],
      ["1 Chronicles", 29], ["2 Chronicles", 36], ["Ezra", 10], ["Nehemiah", 13],
      ["Esther", 10], ["Job", 42], ["Ecclesiastes", 12], ["Song of Solomon", 8],
      ["Isaiah", 66], ["Jeremiah", 52], ["Lamentations", 5], ["Ezekiel", 48],
      ["Daniel", 12], ["Hosea", 14], ["Joel", 3], ["Amos", 9], ["Obadiah", 1],
      ["Jonah", 4], ["Micah", 7], ["Nahum", 3], ["Habakkuk", 3], ["Zephaniah", 3],
      ["Haggai", 2], ["Zechariah", 14], ["Malachi", 4]
    ].freeze

    NT = [
      ["Matthew", 28], ["Mark", 16], ["Luke", 24], ["John", 21], ["Acts", 28],
      ["Romans", 16], ["1 Corinthians", 16], ["2 Corinthians", 13], ["Galatians", 6],
      ["Ephesians", 6], ["Philippians", 4], ["Colossians", 4], ["1 Thessalonians", 5],
      ["2 Thessalonians", 3], ["1 Timothy", 6], ["2 Timothy", 4], ["Titus", 3],
      ["Philemon", 1], ["Hebrews", 13], ["James", 5], ["1 Peter", 5], ["2 Peter", 3],
      ["1 John", 5], ["2 John", 1], ["3 John", 1], ["Jude", 1], ["Revelation", 22]
    ].freeze

    PP = [["Psalm", 150], ["Proverbs", 31]].freeze

    TRACKS = {
      "ot" => { key: "ot", label: "Old Testament",     color: "#2f6a67" },
      "nt" => { key: "nt", label: "New Testament",     color: "#8a2f3b" },
      "pp" => { key: "pp", label: "Psalms & Proverbs", color: "#a5812c" }
    }.freeze

    module_function

    # ---- shared helpers ---------------------------------------------------

    def flatten(track)
      track.flat_map { |book, chapters| (1..chapters).map { |c| [book, c] } }
    end

    def verses_for(book, chapter)
      Versification.verses(book, chapter)
    end

    # Collapse consecutive whole chapters in the same book: "Genesis 1–3, Exodus 1"
    def format_reference(chapters)
      return nil if chapters.empty?

      parts = []
      i = 0
      while i < chapters.size
        book = chapters[i][0]
        start = chapters[i][1]
        j = i
        while j + 1 < chapters.size &&
              chapters[j + 1][0] == book &&
              chapters[j + 1][1] == chapters[j][1] + 1
          j += 1
        end
        last = chapters[j][1]
        parts << (start == last ? "#{book} #{start}" : "#{book} #{start}\u2013#{last}")
        i = j + 1
      end
      parts.join(", ")
    end

    # Group ordered items (each [book, chapter]) into `bins` contiguous groups so
    # that the total weight per group is as even as possible, while guaranteeing
    # every group gets at least one item.
    def balance_by_weight(items, weights, bins)
      n = items.size
      total = weights.sum.to_f
      groups = Array.new(bins) { [] }
      idx = 0
      running = 0.0
      (0...bins).each do |d|
        target = (d + 1) * total / bins
        # every bin takes at least one item
        groups[d] << items[idx]
        running += weights[idx]
        idx += 1
        # then add more only while it brings this bin's cumulative closer to the
        # target boundary (round-to-nearest), keeping one item in reserve per
        # remaining bin
        while idx < n && (n - idx) > (bins - d - 1)
          w = weights[idx]
          break if running >= target
          # stop if overshooting the target would be worse than stopping short
          break if (running + w - target) > (target - running)

          groups[d] << items[idx]
          running += w
          idx += 1
        end
      end
      groups[bins - 1].concat(items[idx...n]) if idx < n
      groups
    end

    # ---- dividing chapters to fill a fixed number of days ------------------
    #
    # Whole chapters are preferred; when a track has fewer chapters than days to
    # fill, the longest chapters are divided until the counts match. Each extra
    # division goes to whichever chapter currently carries the heaviest reading,
    # so the longest are always split first.

    # weights: verses per chapter, in order. pinned: {index => fixed part count}.
    # Returns the number of readings each chapter becomes.
    def divide_to_fill(weights, target, pinned = {})
      parts = Array.new(weights.size, 1)
      pinned.each { |i, n| parts[i] = n }
      candidates = (0...weights.size).reject { |i| pinned.key?(i) }

      while parts.sum < target && candidates.any?
        heaviest = candidates.max_by { |i| weights[i].fdiv(parts[i]) }
        parts[heaviest] += 1
      end
      parts
    end

    # Turn [book, chapter] pairs plus a part count into readings. A reading is
    # [book, chapter] when whole, or [book, chapter, from, to] when it's a slice.
    def expand_readings(chapters, parts)
      chapters.each_with_index.flat_map do |(book, chapter), idx|
        n = parts[idx]
        next [[book, chapter]] if n == 1

        total = verses_for(book, chapter)
        base = total / n
        extra = total % n
        v = 1
        n.times.map do |k|
          size = base + (k < extra ? 1 : 0)
          reading = [book, chapter, v, v + size - 1]
          v += size
          reading
        end
      end
    end

    def segment_length(segment)
      segment.size == 2 ? verses_for(segment[0], segment[1]) : (segment[3] - segment[2] + 1)
    end

    # "Luke 2" for a whole chapter, "Luke 1:1\u201340" for part of one.
    def format_segment(segment)
      book, chapter, from, to = segment
      return "#{book} #{chapter}" if from.nil?

      from == to ? "#{book} #{chapter}:#{from}" : "#{book} #{chapter}:#{from}\u2013#{to}"
    end

    # Chapters that ended up divided, as {[book, chapter] => reading count}.
    def divided(chapters, parts)
      chapters.each_with_index.select { |_, i| parts[i] > 1 }
              .to_h { |ch, i| [ch, parts[i]] }
    end

    # ---- Old Testament ----------------------------------------------------

    def ot_groups
      @ot_groups ||= begin
        chapters = flatten(OT)
        weights  = chapters.map { |b, c| verses_for(b, c) }
        balance_by_weight(chapters, weights, DAYS)
      end
    end

    def ot_plan
      @ot_plan ||= ot_groups.map { |g| format_reference(g) }
    end

    def ot_verse_loads
      @ot_verse_loads ||= ot_groups.map { |g| g.sum { |b, c| verses_for(b, c) } }
    end

    # ---- New Testament (read once, one reading every day) ------------------
    #
    # 260 chapters over 270 days, so the 10 longest chapters are each divided in
    # two — Luke 1, Matthew 26 and 27, Mark 14, Luke 9, 12 and 22, John 6 and 8,
    # and Acts 7. That gives exactly one reading a day with no days off, and
    # brings the longest reading down from Luke 1's 80 verses to 58.

    NT_PASSES = 1

    def nt_chapters = @nt_chapters ||= flatten(NT)

    def nt_parts
      @nt_parts ||= divide_to_fill(nt_chapters.map { |b, c| verses_for(b, c) }, DAYS)
    end

    def nt_readings
      @nt_readings ||= expand_readings(nt_chapters, nt_parts)
    end

    def nt_plan
      @nt_plan ||= nt_readings.map { |seg| format_segment(seg) }
    end

    def nt_verse_loads
      @nt_verse_loads ||= nt_readings.map { |seg| segment_length(seg) }
    end

    # Every day now carries a New Testament reading.
    def nt_content_days = @nt_content_days ||= nt_plan.count { |r| !r.nil? }

    def nt_rest_days = []

    def divided_nt_chapters = @divided_nt_chapters ||= divided(nt_chapters, nt_parts)

    # ---- Psalms & Proverbs -------------------------------------------------
    #
    # Psalms once and Proverbs TWICE across the 270 days, in one daily track.
    #
    # Proverbs supplies 31 x 2 = 62 readings (whole chapters), leaving 208 days
    # for the Psalms. Since there are only 150 psalms, longer ones are divided:
    #
    #   * Psalm 119 is pinned to 11 sections of exactly 16 verses (176 = 11 x 16),
    #     which matches its 22 eight-verse acrostic stanzas, two per section.
    #   * The remaining 48 divisions go to whichever psalm currently carries the
    #     heaviest reading, so the longest are split first and no single reading
    #     runs long.
    #
    # The 62 Proverbs readings are then spaced evenly through the 270 days, which
    # lands Proverbs 31 on day 135 and again on day 270.

    PROVERBS_PASSES        = 2
    PSALM_119_SECTION_SIZE = 16

    def proverbs_reading_count = flatten([["Proverbs", 31]]).size * PROVERBS_PASSES

    def psalm_reading_count = DAYS - proverbs_reading_count

    def psalm_chapters
      @psalm_chapters ||= (1..Versification.chapter_count("Psalm")).map { |c| ["Psalm", c] }
    end

    # How many readings each psalm is divided into (index 0 == Psalm 1).
    # Psalm 119 is pinned to 11 sections of PSALM_119_SECTION_SIZE verses.
    def psalm_parts
      @psalm_parts ||= begin
        weights = psalm_chapters.map { |b, c| verses_for(b, c) }
        i119 = 118
        divide_to_fill(weights, psalm_reading_count, i119 => weights[i119] / PSALM_119_SECTION_SIZE)
      end
    end

    def psalm_readings
      @psalm_readings ||= expand_readings(psalm_chapters, psalm_parts)
    end

    # Proverbs 1..31, repeated PROVERBS_PASSES times, always whole chapters.
    def proverbs_readings
      @proverbs_readings ||= begin
        chapters = (1..Versification.chapter_count("Proverbs")).map { |c| ["Proverbs", c] }
        chapters * PROVERBS_PASSES
      end
    end

    # True when the given 1-indexed day is one of the evenly spaced Proverbs days.
    def proverbs_day?(day)
      n = proverbs_reading_count
      (day * n / DAYS) > ((day - 1) * n / DAYS)
    end

    # One reading per day, Psalms and Proverbs interleaved.
    def pp_readings
      @pp_readings ||= begin
        psalms = psalm_readings.dup
        proverbs = proverbs_readings.dup
        (1..DAYS).map { |day| proverbs_day?(day) ? proverbs.shift : psalms.shift }
      end
    end

    def pp_plan
      @pp_plan ||= pp_readings.map { |seg| format_segment(seg) }
    end

    def pp_verse_loads
      @pp_verse_loads ||= pp_readings.map { |seg| segment_length(seg) }
    end

    # 1-indexed days carrying a Proverbs reading.
    def proverbs_days
      @proverbs_days ||= (1..DAYS).select { |d| proverbs_day?(d) }
    end

    # Psalms that end up divided, as {chapter => number of readings}.
    def divided_psalms
      @divided_psalms ||= divided(psalm_chapters, psalm_parts).to_h { |ch, n| [ch[1], n] }
    end

    # ---- public API -------------------------------------------------------

    def readings_for(day)
      { "ot" => ot_plan[day - 1], "nt" => nt_plan[day - 1], "pp" => pp_plan[day - 1] }
    end

    def present_tracks(day)
      readings_for(day).select { |_, ref| ref }.keys
    end

    def required_track_count(day) = present_tracks(day).size

    def valid_day?(day) = day.is_a?(Integer) && day >= 1 && day <= DAYS

    # ---- calendar mapping (all pure functions; nil start_date = undated) ----

    # Coerce whatever we were handed into a Date (or nil).
    def to_date(value)
      case value
      when nil then nil
      when ::Date then value
      when ::Time then value.to_date
      when ::String then (::Date.parse(value) rescue nil)
      else value.respond_to?(:to_date) ? value.to_date : nil
      end
    end

    # The calendar date a given plan day falls on.
    def date_for(day, start_date)
      start = to_date(start_date)
      return nil unless start && valid_day?(day)

      start + (day - 1)
    end

    # The last day of the plan.
    def end_date_for(start_date)
      date_for(DAYS, start_date)
    end

    # Which plan day a calendar date corresponds to. By default the result is
    # clamped into 1..DAYS; pass clamp: false to get the raw (possibly out of
    # range) offset, which is how you tell "hasn't started yet" from "day 1".
    def day_for(date, start_date, clamp: true)
      start = to_date(start_date)
      on    = to_date(date)
      return nil unless start && on

      offset = (on - start).to_i + 1
      clamp ? offset.clamp(1, DAYS) : offset
    end

    def before_start?(date, start_date)
      raw = day_for(date, start_date, clamp: false)
      raw ? raw < 1 : false
    end

    def after_end?(date, start_date)
      raw = day_for(date, start_date, clamp: false)
      raw ? raw > DAYS : false
    end

    def totals
      {
        ot: flatten(OT).size,                  # 748 chapters
        nt: flatten(NT).size,                  # 260 chapters, read once
        nt_passes: NT_PASSES,
        nt_readings: nt_readings.size,          # 270 - one every day
        nt_divided: divided_nt_chapters.size,   # 10 long chapters halved
        psalms: Versification.chapter_count("Psalm"),        # 150
        psalm_readings: psalm_readings.size,                 # 208
        proverbs: Versification.chapter_count("Proverbs"),   # 31
        proverbs_passes: PROVERBS_PASSES,
        proverbs_readings: proverbs_reading_count,           # 62
        pp: flatten(PP).size,                  # 181 chapters
        pp_verses: flatten(PP).sum { |b, c| verses_for(b, c) },
        ot_verses: flatten(OT).sum { |b, c| verses_for(b, c) },
        nt_verses: flatten(NT).sum { |b, c| verses_for(b, c) },
        days: DAYS
      }
    end
  end
end
