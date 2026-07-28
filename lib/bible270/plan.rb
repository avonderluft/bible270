# frozen_string_literal: true

require 'date'
require 'yaml'
require 'bible270/versification'

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
  # Genesis → Malachi, Revelation 22, Psalm 150 and the second Proverbs 31 all land
  # in the closing days.
  module Plan
    DAYS = 270

    OT = [
      ['Genesis', 50], ['Exodus', 40], ['Leviticus', 27], ['Numbers', 36],
      ['Deuteronomy', 34], ['Joshua', 24], ['Judges', 21], ['Ruth', 4],
      ['1 Samuel', 31], ['2 Samuel', 24], ['1 Kings', 22], ['2 Kings', 25],
      ['1 Chronicles', 29], ['2 Chronicles', 36], ['Ezra', 10], ['Nehemiah', 13],
      ['Esther', 10], ['Job', 42], ['Ecclesiastes', 12], ['Song of Solomon', 8],
      ['Isaiah', 66], ['Jeremiah', 52], ['Lamentations', 5], ['Ezekiel', 48],
      ['Daniel', 12], ['Hosea', 14], ['Joel', 3], ['Amos', 9], ['Obadiah', 1],
      ['Jonah', 4], ['Micah', 7], ['Nahum', 3], ['Habakkuk', 3], ['Zephaniah', 3],
      ['Haggai', 2], ['Zechariah', 14], ['Malachi', 4]
    ].freeze

    NT = [
      ['Matthew', 28], ['Mark', 16], ['Luke', 24], ['John', 21], ['Acts', 28],
      ['Romans', 16], ['1 Corinthians', 16], ['2 Corinthians', 13], ['Galatians', 6],
      ['Ephesians', 6], ['Philippians', 4], ['Colossians', 4], ['1 Thessalonians', 5],
      ['2 Thessalonians', 3], ['1 Timothy', 6], ['2 Timothy', 4], ['Titus', 3],
      ['Philemon', 1], ['Hebrews', 13], ['James', 5], ['1 Peter', 5], ['2 Peter', 3],
      ['1 John', 5], ['2 John', 1], ['3 John', 1], ['Jude', 1], ['Revelation', 22]
    ].freeze

    PP = [['Psalm', 150], ['Proverbs', 31]].freeze

    TRACKS = {
      'ot' => { key: 'ot', label: 'Old Testament',     color: '#2f6a67' },
      'nt' => { key: 'nt', label: 'New Testament',     color: '#8a2f3b' },
      'pp' => { key: 'pp', label: 'Psalms & Proverbs', color: '#a5812c' }
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
      parts.join(', ')
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

      if parts.sum > target
        raise ArgumentError,
              "pinned chapter breaks need #{parts.sum} readings but only #{target} are available; " \
              'remove some CHAPTER_BREAKS entries or lengthen the plan'
      end

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

        boundaries(book, chapter, n).map { |from, to| [book, chapter, from, to] }
      end
    end

    # [[from, to], ...] for a chapter divided into n readings: the break points
    # from CHAPTER_BREAKS when given, otherwise equal parts.
    def boundaries(book, chapter, parts)
      total = verses_for(book, chapter)
      explicit = chapter_breaks_for(book, chapter)
      last_verses = explicit || even_break_points(total, parts)

      from = 1
      (last_verses + [total]).map do |to|
        range = [from, to]
        from = to + 1
        range
      end
    end

    def even_break_points(total, parts)
      base = total / parts
      extra = total % parts
      v = 0
      (parts - 1).times.map do |k|
        v += base + (k < extra ? 1 : 0)
        v
      end
    end

    # Validated on the way out so a typo fails loudly instead of silently
    # producing overlapping or out-of-range readings.
    def chapter_breaks_for(book, chapter)
      points = configured_breaks[[book, chapter]]
      return nil if points.nil?

      total = verses_for(book, chapter)
      unless points == points.sort.uniq && points.all? { |v| v.is_a?(Integer) && v.between?(1, total - 1) }
        raise ArgumentError,
              "CHAPTER_BREAKS[#{[book, chapter].inspect}] must be ascending, distinct " \
              "verse numbers between 1 and #{total - 1}, got #{points.inspect}"
      end

      points
    end

    # {index => reading count} for chapters whose breaks are set explicitly.
    def pinned_from_breaks(chapters)
      chapters.each_with_index.filter_map do |(book, chapter), idx|
        points = configured_breaks[[book, chapter]]
        [idx, points.size + 1] if points
      end.to_h
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

    # ---- memoisation ------------------------------------------------------
    #
    # Everything derived from the plan is cached together so that reset! (used by
    # the tests, and by anything that changes CHAPTER_BREAKS at runtime) drops it
    # all at once rather than leaving a half-rebuilt plan.

    def memo(key)
      fingerprint = configured_breaks
      if @cache_fingerprint != fingerprint
        @cache = {}
        @cache_fingerprint = fingerprint
      end
      @cache ||= {}
      return @cache[key] if @cache.key?(key)

      @cache[key] = yield
    end

    def reset!
      @cache = {}
      @cache_fingerprint = nil
      true
    end

    # ---- where the break points come from ---------------------------------
    #
    # Three sources, later winning: the CHAPTER_BREAKS constant, then
    # Bible270.config.chapter_breaks, then a YAML file at
    # Bible270.config.chapter_breaks_path. The file is re-read whenever it
    # changes, so break points can be tuned without restarting the server.

    def configured_breaks
      base = CHAPTER_BREAKS.merge(config_breaks)
      path = breaks_file_path
      path ? base.merge(file_breaks(path)) : base
    end

    def config_breaks
      return {} unless bible270_config.respond_to?(:chapter_breaks)

      normalize_breaks(bible270_config.chapter_breaks || {})
    end

    def breaks_file_path
      return nil unless bible270_config.respond_to?(:chapter_breaks_path)

      path = bible270_config.chapter_breaks_path
      path && File.exist?(path.to_s) ? path.to_s : nil
    end

    def bible270_config
      Bible270.respond_to?(:config) ? Bible270.config : nil
    end

    # Cached against mtime and size: an edit is picked up, an unchanged file is
    # not re-parsed on every request.
    def file_breaks(path)
      stat = File.stat(path)
      stamp = [path, stat.mtime.to_f, stat.size]
      return @file_breaks if @file_breaks_stamp == stamp

      @file_breaks_stamp = stamp
      @file_breaks = parse_breaks_file(path)
    end

    def parse_breaks_file(path)
      raw = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
      raise ArgumentError, "#{path} must map \"Book Chapter\" to a list of verses" unless raw.is_a?(Hash)

      normalize_breaks(raw)
    rescue Psych::SyntaxError => e
      raise ArgumentError, "#{path} is not valid YAML: #{e.message}"
    end

    # Keys may be ['Psalm', 18] or 'Psalm 18'; a nil value means "keep whole".
    def normalize_breaks(hash)
      hash.to_h { |key, value| [break_key(key), Array(value).map(&:to_i)] }
    end

    def break_key(key)
      return [key[0].to_s, key[1].to_i] if key.is_a?(Array)

      match = key.to_s.strip.match(/\A(.+?)\s+(\d+)\z/)
      raise ArgumentError, "chapter break key #{key.inspect} must look like 'Psalm 18'" if match.nil?

      [match[1], match[2].to_i]
    end

    # ---- Old Testament ----------------------------------------------------

    def ot_groups
      memo(:ot_groups) do
        chapters = flatten(OT)
        weights  = chapters.map { |b, c| verses_for(b, c) }
        balance_by_weight(chapters, weights, DAYS)
      end
    end

    def ot_plan
      memo(:ot_plan) { ot_groups.map { |g| format_reference(g) } }
    end

    def ot_verse_loads
      memo(:ot_verse_loads) { ot_groups.map { |g| g.sum { |b, c| verses_for(b, c) } } }
    end

    # ---- New Testament (read once, one reading every day) ------------------
    #
    # 260 chapters over 270 days, so the 10 longest chapters are each divided in
    # two — Luke 1, Matthew 26 and 27, Mark 14, Luke 9, 12 and 22, John 6 and 8,
    # and Acts 7. That gives exactly one reading a day with no days off, and
    # brings the longest reading down from Luke 1's 80 verses to 58.

    NT_PASSES = 1

    def nt_chapters = memo(:nt_chapters) { flatten(NT) }

    def nt_parts
      memo(:nt_parts) { divide_to_fill(nt_chapters.map { |b, c| verses_for(b, c) }, DAYS, pinned_from_breaks(nt_chapters)) }
    end

    def nt_readings
      memo(:nt_readings) { expand_readings(nt_chapters, nt_parts) }
    end

    def nt_plan
      memo(:nt_plan) { nt_readings.map { |seg| format_segment(seg) } }
    end

    def nt_verse_loads
      memo(:nt_verse_loads) { nt_readings.map { |seg| segment_length(seg) } }
    end

    # Every day now carries a New Testament reading.
    def nt_content_days = memo(:nt_content_days) { nt_plan.count { |r| !r.nil? } }

    def nt_rest_days = []

    def divided_nt_chapters = memo(:divided_nt_chapters) { divided(nt_chapters, nt_parts) }

    # ---- Psalms & Proverbs -------------------------------------------------
    #
    # Psalms once and Proverbs once, interleaved in one daily track.
    #
    # 150 + 31 = 181 chapters have to cover 270 days, so 89 of them are divided.
    # Two rules shape which:
    #
    #   * A psalm of PSALM_WHOLE_MAX_VERSES verses or fewer is never divided.
    #     That locks 131 of the 150 psalms whole.
    #   * Psalm 119 is pinned to sections of PSALM_119_SECTION_SIZE verses.
    #
    # The remaining divisions are shared between the eligible psalms and Proverbs
    # by verse load — each one goes to whichever chapter currently carries the
    # heaviest reading — so both books end up with readings of about the same
    # length and Proverbs lands on roughly its proportional share of the days.
    # CHAPTER_BREAKS overrides any of it.
    #
    # A divided chapter is always read on consecutive days: readings are grouped
    # by chapter and the two books interleaved a whole chapter at a time, so
    # nothing is ever inserted between the parts of a split psalm.

    # ---- where divided chapters break -------------------------------------
    #
    # EDIT THIS to choose your own break points. Keys are [book, chapter];
    # the value lists the LAST VERSE of every reading except the final one.
    #
    #   ['Luke', 1] => [25, 56]   # => Luke 1:1-25, 1:26-56, 1:57-80
    #   ['Psalm', 78] => [39]     # => Psalm 78:1-39, 78:40-72
    #
    # The number of readings a chapter becomes is then fixed by the number of
    # breaks you give it, and the rest of the plan re-divides around it to still
    # fill exactly DAYS days. Anything not listed here is split into equal parts.
    CHAPTER_BREAKS = {
      ['Psalm', 9] => [], ['Psalm', 10] => [], # Stay whole
      ['Psalm', 18] => [24], # => Psalm 18:1–24, 18:25–50
      ['Psalm', 22] => [21], # => Psalm 22:1–21, 22:22–31
      ['Psalm', 31] => [], ['Psalm', 33] => [], ['Psalm', 34] => [], ['Psalm', 38] => [], # Stay whole
      ['Psalm', 44] => [], ['Psalm', 49] => [], ['Psalm', 50] => [], ['Psalm', 51] => [], # Stay whole
      ['Psalm', 55] => [], ['Psalm', 59] => [], ['Psalm', 65] => [], ['Psalm', 66] => [], # Stay whole
      ['Psalm', 68] => [18], # => Psalm 68:1–18, 68:19–35
      ['Psalm', 69] => [18 ], # => Psalm 69:1–18, 69:19–36
      ['Psalm', 78] => [20, 39, 55], # => 78:1–20, 21–39, 40–55, 56–72
      ['Psalm', 37] => [20], # => Psalm 37:1–20, 37:21–40
      ['Matthew', 26] => [35], # => Matthew 26:1–35, 26:36–75
      ['Matthew', 27] => [31], # => Matthew 27:1–31
      ['Mark', 14] => [31],    # => Mark 14:1–31, 14:32–72
      ['Luke', 1] => [25, 56], # => Luke 1:1–25, 1:26–56, 1:57–80
      ['Luke', 9] => [36], # => Luke 9:1–36, 9:37–62
      ['Luke', 11] => [26], # => Luke 11:1–26, 11:27–54
      ['Luke', 22] => [38], # => Luke 22:1–38, 22:39–71
      ['John', 6] => [40], # => John 6:1–40, 6:41–71
      ['Acts', 7] => [36], # => Acts 7:1–36, 7:37–60

      # -- Psalms over 25 verses, divided at their turns of thought ----------
      ['Psalm', 35] => [],             # kept whole
      ['Psalm', 73] => [14],           # the envious lament | the sanctuary
      ['Psalm', 89] => [18, 37],       # hymn | covenant oracle | lament
      ['Psalm', 102] => [17],          # affliction | Zion restored
      ['Psalm', 104] => [18],          # creation ordered | creation sustained
      ['Psalm', 105] => [22],          # covenant and Joseph | exodus
      ['Psalm', 106] => [23],          # praise and wilderness | Canaan and mercy
      ['Psalm', 107] => [16, 32],      # wanderers and prisoners | sick and storm-tossed | coda
      ['Psalm', 109] => [20],          # the imprecation | the plea
      ['Psalm', 118] => [18],          # thanksgiving | the gate of the LORD
      ['Psalm', 136] => [],            # the refrain psalm, kept whole

      # -- Proverbs: the discourses of 1-9 and the appendices of 30-31 have
      #    real structure, so they break at it. Chapters 10-29 are collections
      #    of independent sayings with no narrative flow, so they are divided
      #    evenly; add entries here if you prefer particular groupings.
      ['Proverbs', 1] => [7, 19],      # prologue | enticement of sinners | Wisdom calls
      ['Proverbs', 2] => [9],          # the search for wisdom | its protection
      ['Proverbs', 3] => [12, 26],     # trust and discipline | wisdom's worth | neighbourly justice
      ['Proverbs', 4] => [9, 19],      # a father's teaching | the two paths | guard the heart
      ['Proverbs', 5] => [14],         # the adulteress | your own cistern
      ['Proverbs', 6] => [19],         # surety, sluggard, seven abominations | adultery
      ['Proverbs', 7] => [5, 23],      # keep my commands | the seduction | her house
      ['Proverbs', 8] => [11, 21],     # Wisdom calls | her worth | Wisdom at creation
      ['Proverbs', 9] => [6, 12],      # Wisdom's feast | scoffer and wise | Folly's feast
      ['Proverbs', 30] => [9, 17],     # Agur's confession | four sayings | the numbered proverbs
      ['Proverbs', 22] => [16],        # sayings | words of the wise
      ['Proverbs', 23] => [8, 21, 28],
      ['Proverbs', 24] => [12, 22],
      ['Proverbs', 26] => [12, 19],    # the fool | the sluggard | the quarreller
      ['Proverbs', 27] => [10, 17],
      ['Proverbs', 28] => [12, 18],
      ['Proverbs', 31] => [9]          # King Lemuel | the woman of valour
    }.freeze

    # A psalm this short or shorter is never divided.
    PSALM_WHOLE_MAX_VERSES = 25

    PSALM_119_SECTION_SIZE = 16

    def psalm_chapters
      memo(:psalm_chapters) { (1..Versification.chapter_count('Psalm')).map { |c| ['Psalm', c] } }
    end

    def proverbs_chapters
      memo(:proverbs_chapters) { (1..Versification.chapter_count('Proverbs')).map { |c| ['Proverbs', c] } }
    end

    def pp_chapters = memo(:pp_chapters) { psalm_chapters + proverbs_chapters }

    # Psalms and Proverbs are divided together against a single budget of DAYS
    # readings, so the two books balance against each other by verse load rather
    # than each being squeezed into a fixed number of days.
    def pp_parts
      memo(:pp_parts) do
        chapters = pp_chapters
        weights  = chapters.map { |b, c| verses_for(b, c) }
        divide_to_fill(weights, DAYS, pp_pinned_parts(chapters, weights))
      end
    end

    def pp_pinned_parts(chapters, weights)
      pinned = {}
      chapters.each_with_index do |(book, chapter), idx|
        next unless book == 'Psalm'

        pinned[idx] = 1 if weights[idx] <= PSALM_WHOLE_MAX_VERSES
        pinned[idx] = weights[idx] / PSALM_119_SECTION_SIZE if chapter == 119
      end
      # An explicit entry in CHAPTER_BREAKS always wins.
      pinned.merge(pinned_from_breaks(chapters))
    end

    def psalm_parts    = memo(:psalm_parts)    { pp_parts.first(psalm_chapters.size) }
    def proverbs_parts = memo(:proverbs_parts) { pp_parts.last(proverbs_chapters.size) }

    def psalm_readings    = memo(:psalm_readings)    { expand_readings(psalm_chapters, psalm_parts) }
    def proverbs_readings = memo(:proverbs_readings) { expand_readings(proverbs_chapters, proverbs_parts) }

    # Readings grouped by chapter, so a divided chapter stays together.
    def psalm_groups    = memo(:psalm_groups)    { group_by_chapter(psalm_readings) }
    def proverbs_groups = memo(:proverbs_groups) { group_by_chapter(proverbs_readings) }

    def group_by_chapter(readings)
      readings.chunk_while { |a, b| a[0] == b[0] && a[1] == b[1] }.to_a
    end

    # Interleave the two books a whole chapter at a time, spacing the Proverbs
    # chapters evenly through the Psalms. Because a group is emitted in one go,
    # nothing can land between the parts of a divided chapter.
    def pp_readings
      memo(:pp_readings) do
        psalms   = psalm_groups
        proverbs = proverbs_groups
        placed   = 0
        days     = []

        psalms.each_with_index do |group, i|
          days.concat(group)
          due = ((i + 1) * proverbs.size) / psalms.size
          while placed < due
            days.concat(proverbs[placed])
            placed += 1
          end
        end
        days.concat(proverbs[placed..].to_a.flatten(1)) if placed < proverbs.size
        days
      end
    end

    def pp_plan        = memo(:pp_plan)        { pp_readings.map { |seg| format_segment(seg) } }
    def pp_verse_loads = memo(:pp_verse_loads) { pp_readings.map { |seg| segment_length(seg) } }

    # 1-indexed days carrying a Proverbs reading.
    def proverbs_days
      memo(:proverbs_days) { (1..DAYS).select { |d| pp_readings[d - 1][0] == 'Proverbs' } }
    end

    def divided_psalms
      memo(:divided_psalms) { divided(psalm_chapters, psalm_parts).to_h { |ch, n| [ch[1], n] } }
    end

    def divided_proverbs
      memo(:divided_proverbs) { divided(proverbs_chapters, proverbs_parts).to_h { |ch, n| [ch[1], n] } }
    end

    # ---- public API -------------------------------------------------------

    def readings_for(day)
      { 'ot' => ot_plan[day - 1], 'nt' => nt_plan[day - 1], 'pp' => pp_plan[day - 1] }
    end

    def present_tracks(day)
      readings_for(day).select { |_, ref| ref }.keys
    end

    def required_track_count(day) = present_tracks(day).size

    def valid_day?(day) = day.is_a?(Integer) && day >= 1 && day <= DAYS

    # Blank means "the whole day", which is stored as NULL. Select fields submit
    # an empty string rather than nil, so this has to be normalised before
    # validation or the inclusion check rejects it.
    def normalize_track(value)
      track = value.to_s.strip
      return nil if track.empty?

      track
    end

    def valid_track?(value)
      track = normalize_track(value)
      track.nil? || TRACKS.key?(track)
    end

    # ---- calendar mapping (all pure functions; nil start_date = undated) ----

    # Coerce whatever we were handed into a Date (or nil).
    def to_date(value)
      case value
      when nil then nil
      when ::Date then value
      when ::Time then value.to_date
      when ::String then begin
        ::Date.parse(value)
      rescue StandardError
        nil
      end
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
        psalms: Versification.chapter_count('Psalm'),        # 150
        psalm_readings: psalm_readings.size,                 # 208
        proverbs: Versification.chapter_count('Proverbs'),   # 31
        proverbs_readings: proverbs_readings.size,
        proverbs_divided: divided_proverbs.size,
        psalms_whole_max_verses: PSALM_WHOLE_MAX_VERSES,
        pp: flatten(PP).size, # 181 chapters
        pp_verses: flatten(PP).sum { |b, c| verses_for(b, c) },
        ot_verses: flatten(OT).sum { |b, c| verses_for(b, c) },
        nt_verses: flatten(NT).sum { |b, c| verses_for(b, c) },
        days: DAYS
      }
    end
  end
end
