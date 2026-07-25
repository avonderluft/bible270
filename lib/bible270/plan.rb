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
  # * Old Testament   – read once, cover to cover; WHOLE chapters grouped so each
  #                     day is ~equal in verses (~73/day)
  # * New Testament   – read through TWICE (~2 chapters/day, every day)
  # * Psalms/Proverbs – a WHOLE-CHAPTER daily companion. With only 181 chapters
  #                     over 270 days it cycles ~1.9x. Chapters stay intact; very
  #                     short ones merge with a neighbour, and the one excessively
  #                     long chapter (Psalm 119) is divided into two readings.
  #
  # Genesis→Malachi finishes on day 270, as does the second pass through the NT.
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

    # ---- New Testament (read through TWICE) -------------------------------
    #
    # 260 chapters x 2 passes = 520 chapter-readings over 270 days, so ~2 chapters
    # a day and no rest days. Each pass gets its own half of the plan (135 days),
    # so Revelation 22 lands on day 135 and again on day 270. Within a pass, whole
    # chapters are grouped so each day is ~equal in verses.

    NT_PASSES = 2

    def nt_days_per_pass = DAYS / NT_PASSES

    def nt_chapters
      @nt_chapters ||= flatten(NT) * NT_PASSES
    end

    def nt_groups
      @nt_groups ||= begin
        chapters = flatten(NT)
        weights  = chapters.map { |b, c| verses_for(b, c) }
        one_pass = balance_by_weight(chapters, weights, nt_days_per_pass)
        one_pass * NT_PASSES
      end
    end

    def nt_plan
      @nt_plan ||= nt_groups.map { |g| format_reference(g) }
    end

    def nt_verse_loads
      @nt_verse_loads ||= nt_groups.map { |g| g.sum { |b, c| verses_for(b, c) } }
    end

    # Days on which the NT track has content (now every day).
    def nt_content_days
      @nt_content_days ||= nt_plan.count { |r| !r.nil? }
    end

    # 1-indexed day on which the second pass through the NT begins.
    def nt_second_pass_start_day = nt_days_per_pass + 1

    # ---- Psalms & Proverbs (whole-chapter companion, cycles ~1.9x) --------
    #
    # Chapters are kept WHOLE. Because there are only 181 Psalms/Proverbs
    # chapters but 270 days, the track reads through roughly twice, cycling.
    # Two adjustments keep daily portions roughly even without chopping text:
    #   * very short chapters merge with a neighbour (no trivial 2-verse days)
    #   * only excessively long chapters (> PP_LONG_CHAPTER verses) are split
    #     into balanced parts — in practice just Psalms 78, 89, and 119.

    PP_MIN_DAY      = 12  # keep merging until a portion reaches at least this many verses
    PP_DAY_TARGET   = 22  # soft cap: stop merging once a portion would exceed this
    PP_LONG_CHAPTER = 100 # only an excessively long chapter is split; in the whole
                          # Psalter+Proverbs that is Psalm 119 (176v) alone, since
                          # the next longest chapter is Psalm 78 at 72 verses
    PP_SPLIT_PARTS  = 2   # such a chapter is divided into this many readings

    # The base cycle of readings (whole chapters, short ones merged, long ones
    # split). Each portion is an array of segments; a segment is either
    # [book, chapter] (whole) or [book, chapter, from, to] (part of a chapter).
    def pp_base_portions
      @pp_base_portions ||= begin
        units = flatten(PP).map { |b, c| [b, c, verses_for(b, c)] }
        portions = []
        buf = []
        buflen = 0
        units.each do |book, ch, len|
          if len > PP_LONG_CHAPTER
            unless buf.empty?
              portions << buf
              buf = []
              buflen = 0
            end
            nparts = PP_SPLIT_PARTS
            base = len / nparts
            extra = len % nparts
            v = 1
            nparts.times do |i|
              size = base + (i < extra ? 1 : 0)
              portions << [[book, ch, v, v + size - 1]]
              v += size
            end
          else
            if !buf.empty? && buflen >= PP_MIN_DAY && buflen + len > PP_DAY_TARGET
              portions << buf
              buf = []
              buflen = 0
            end
            buf << [book, ch]
            buflen += len
          end
        end
        portions << buf unless buf.empty?
        portions
      end
    end

    def pp_cycle_length = pp_base_portions.size

    def pp_plan
      @pp_plan ||= (0...DAYS).map { |d| format_pp(pp_base_portions[d % pp_cycle_length]) }
    end

    def pp_verse_loads
      @pp_verse_loads ||= (0...DAYS).map do |d|
        pp_base_portions[d % pp_cycle_length].sum do |s|
          s.size == 2 ? verses_for(s[0], s[1]) : (s[3] - s[2] + 1)
        end
      end
    end

    # Format a portion, collapsing consecutive whole chapters ("Psalm 24–25")
    # and rendering split parts as verse ranges ("Psalm 119:1–22").
    def format_pp(portion)
      parts = []
      i = 0
      while i < portion.size
        s = portion[i]
        if s.size == 2 # whole chapter
          book, ch = s
          j = i
          while j + 1 < portion.size && portion[j + 1].size == 2 &&
                portion[j + 1][0] == book && portion[j + 1][1] == portion[j][1] + 1
            j += 1
          end
          last = portion[j][1]
          parts << (ch == last ? "#{book} #{ch}" : "#{book} #{ch}\u2013#{last}")
          i = j + 1
        else # part of a chapter
          book, ch, from, to = s
          parts << (from == to ? "#{book} #{ch}:#{from}" : "#{book} #{ch}:#{from}\u2013#{to}")
          i += 1
        end
      end
      parts.join(", ")
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
        ot: flatten(OT).size,                 # 748 chapters
        nt: flatten(NT).size,                 # 260 chapters per pass
        nt_passes: NT_PASSES,                 # read through twice
        nt_chapters_read: nt_chapters.size,   # 520 chapter-readings
        pp: flatten(PP).size,                 # 181 chapters
        pp_verses: flatten(PP).sum { |b, c| verses_for(b, c) }, # 3376 verses
        pp_cycle: pp_cycle_length,            # base portions before cycling
        ot_verses: flatten(OT).sum { |b, c| verses_for(b, c) },
        nt_verses: nt_chapters.sum { |b, c| verses_for(b, c) },
        days: DAYS
      }
    end
  end
end
