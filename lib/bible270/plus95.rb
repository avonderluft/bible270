# frozen_string_literal: true

module Bible270
  # Fixed calendar extension. Each row (starting at calendar day 271) holds
  # an NT summary and a wisdom summary. Keep the row and passage order stable:
  # stored checkoffs address a passage by calendar day, track, and part index.
  # The schedule favors whole chapters and consecutive chapters within a book.
  # Psalm 1 is already read on day 270. Psalm 119 alone is divided, at its stanza boundaries.
  module Plus95
    SCHEDULE = <<~READINGS
      Matthew 1–4 | Psalm 2–3
      Matthew 5–7 | Psalm 4
      Matthew 8–9 | Psalm 5; Proverbs 1
      Matthew 10 | Psalm 6–10
      Matthew 11–12 | Proverbs 2; Psalm 11–12
      Matthew 13 | Psalm 13–14; Proverbs 3; Psalm 15–16
      Matthew 14–16 | Psalm 17
      Matthew 17–18 | Psalm 18
      Matthew 19–21 | Psalm 19
      Matthew 22–23 | Proverbs 4
      Matthew 24–25 | Psalm 20–21
      Matthew 26 | Psalm 22–24
      Matthew 27–28 | Proverbs 5; Psalm 25
      Mark 1–3 | Psalm 26
      Mark 4–5 | Psalm 27–29
      Mark 6–7 | Proverbs 6
      Mark 8–9 | Psalm 30–31
      Mark 10–11 | Psalm 32–33
      Mark 12 | Proverbs 7; Psalm 34–35
      Mark 13–14 | Psalm 36
      Mark 15–16 | Psalm 37–38
      Luke 1 | Proverbs 8
      Luke 2–3 | Psalm 39–40
      Luke 4–5 | Psalm 41–43
      Luke 6–7 | Proverbs 9
      Luke 8 | Psalm 44–46
      Luke 9 | Psalm 47–48; Proverbs 10
      Luke 10–11 | Psalm 49
      Luke 12–13 | Psalm 50
      Luke 14–16 | Psalm 51–52
      Luke 17–18 | Psalm 53; Proverbs 11; Psalm 54
      Luke 19–20 | Psalm 55
      Luke 21–22 | Psalm 56
      Luke 23–24 | Psalm 57
      John 1–2 | Psalm 58; Proverbs 12
      John 3 | Psalm 59–62; Proverbs 13
      John 4–5 | Psalm 63
      John 6 | Psalm 64–66
      John 7–8 | Psalm 67
      John 9–10 | Proverbs 14
      John 11 | Psalm 68–69
      John 12–13 | Psalm 70–71
      John 14–15 | Psalm 72; Proverbs 15
      John 16–17 | Psalm 73–75
      John 18–19 | Psalm 76–77
      John 20–21; Acts 1 | Proverbs 16
      Acts 2 | Psalm 78
      Acts 3–5 | Psalm 79
      Acts 6–7 | Psalm 80–82
      Acts 8–9 | Proverbs 17
      Acts 10–12 | Psalm 83
      Acts 13–14 | Psalm 84–86
      Acts 15–17 | Psalm 87
      Acts 18–20 | Proverbs 18
      Acts 21–23 | Psalm 88
      Acts 24–25 | Psalm 89–90
      Acts 26–28 | Psalm 91
      Romans 1–3 | Proverbs 19
      Romans 4–6 | Psalm 92–95
      Romans 7–8 | Psalm 96; Proverbs 20; Psalm 97
      Romans 9–11 | Psalm 98–101
      Romans 12–15 | Proverbs 21
      Romans 16; 1 Corinthians 1–2 | Psalm 102–103
      1 Corinthians 3–6 | Psalm 104
      1 Corinthians 7–9 | Psalm 105
      1 Corinthians 10–11 | Psalm 106
      1 Corinthians 12–14 | Proverbs 22
      1 Corinthians 15–16 | Psalm 107
      2 Corinthians 1–4 | Psalm 108–109
      2 Corinthians 5–9 | Psalm 110–112
      2 Corinthians 10–13 | Proverbs 23
      Galatians 1–4 | Psalm 113–114
      Galatians 5–6 | Psalm 115–116; Proverbs 24
      Ephesians 1–3 | Psalm 117–118; Psalm 119:1–16
      Ephesians 4–6 | Psalm 119:17–40
      Philippians 1–4 | Psalm 119:41–56
      Colossians 1–4 | Psalm 119:57–80
      1 Thessalonians 1–5 | Psalm 119:81–112
      2 Thessalonians 1–3; 1 Timothy 1–2 | Psalm 119:113–144
      1 Timothy 3–6 | Psalm 119:145–176; Psalm 120
      2 Timothy 1–4 | Proverbs 25; Psalm 121
      Titus 1–3; Philemon 1 | Psalm 122–125; Proverbs 26
      Hebrews 1–6 | Psalm 126–128
      Hebrews 7–10 | Psalm 129–130
      Hebrews 11–13 | Proverbs 27; Psalm 131
      James 1–5 | Psalm 132
      1 Peter 1–3 | Psalm 133–135; Proverbs 28
      1 Peter 4–5; 2 Peter 1–3 | Psalm 136
      1 John 1–5 | Psalm 137–138
      2 John 1; 3 John 1; Jude 1 | Psalm 139–140; Proverbs 29
      Revelation 1–5 | Psalm 141–143
      Revelation 6–10 | Psalm 144–145
      Revelation 11–14 | Proverbs 30; Psalm 146
      Revelation 15–18 | Psalm 147–149
      Revelation 19–22 | Psalm 150; Proverbs 31
    READINGS
    private_constant :SCHEDULE

    READINGS = SCHEDULE.lines.map do |row|
      nt, pp = row.chomp.split(' | ')
      { 'ot' => nil, 'nt' => nt.freeze, 'pp' => pp.freeze }.freeze
    end.freeze

    # A joined summary is display text, not necessarily a single valid link.
    # Expand whole chapter ranges, but keep verse ranges as one passage each.
    PARTS = READINGS.map do |day|
      day.compact.transform_values do |summary|
        summary.split('; ').flat_map do |reference|
          range = reference.match(%r{\A(.+) (\d+)–(\d+)\z})
          next [reference.freeze] unless range

          book, first, last = range.captures
          (first.to_i..last.to_i).map { |chapter| "#{book} #{chapter}".freeze }
        end.freeze
      end.freeze
    end.freeze
  end
end
