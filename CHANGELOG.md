# Changelog

All notable changes to bible270. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html), treating pre-1.0 minor
bumps as the place breaking changes may land.

## [0.9.0] — 2026-07-25

### Changed
- **The New Testament now has a reading every day — no days off.** 260 chapters over 270 days is
  reconciled by dividing the 10 longest chapters in two: Luke 1, Matthew 26 and 27, Mark 14,
  Luke 9, 12 and 22, John 6 and 8, and Acts 7. Luke 1 reads as 1–40 then 41–80. This drops the
  longest NT reading from 80 verses to 58 (stdev 14.6 → 11.4) and removes the 10 rest days from
  0.8.0, so all three tracks are present on all 270 days and every day needs three check-offs.
- The daily total is now 76–175 verses (was 76–203), averaging ~119.

### Added
- Shared division machinery used by both the NT and the Psalms: `Plan.divide_to_fill`,
  `expand_readings`, `segment_length`, `format_segment`, `divided`.
- `Plan.nt_parts`, `nt_readings`, `nt_chapters`, `divided_nt_chapters`, `psalm_chapters`.
- `totals` reports `nt_readings` (270) and `nt_divided` (10).

### Removed
- `Plan.nt_groups`, `format_pp_segment`, `pp_segment_length` (superseded by the shared
  `format_segment` and `segment_length`), and `totals[:nt_rest_days]`.
- `nt_rest_days` remains but now always returns an empty array.

## [0.8.0] — 2026-07-25

### Changed — BREAKING (the reading plan itself)
- **New Testament is read once**, not twice: one chapter a day with 10 evenly spaced days off
  (every 27th). Matthew 1 on day 1, Revelation 22 on day 270. Chapters stay whole, so the NT load
  swings with chapter length (8–80 verses: Revelation 15 to Luke 1). Verse-balancing the NT would
  have needed 48 rest days,
  since 260 whole chapters can't spread evenly over 270 days — one-a-day is the better trade.
- **Psalms once and Proverbs twice**, interleaved in the third track. Proverbs contributes
  31 × 2 = 62 whole-chapter readings, spaced evenly, which leaves 208 days for the Psalms.
- **Psalm 119 is divided into 11 sections of exactly 16 verses** (176 = 11 × 16 — two of its
  eight-verse acrostic stanzas per reading), replacing the previous two-part split.
- **Longer psalms are divided to fill the remaining days.** After Psalm 119's 11 sections, 48 further
  divisions are spent on whichever psalm currently carries the heaviest reading, so the longest go
  first: 41 psalms end up divided and no single psalm reading exceeds 20 verses.
- Short psalms are no longer merged with a neighbour — the track now needs more readings, not fewer,
  so every psalm stands on its own day or is divided. Psalm 117 is a light day (2 verses) on that
  track, though the day still carries its OT and NT readings.
- Proverbs 31 lands on day 135 and again on day 270; Psalm 150 on day 269.
- A typical day is now ~119 verses (range 76–203), down from ~157.

### Added
- `Plan.psalm_parts`, `psalm_readings`, `proverbs_readings`, `pp_readings`, `proverbs_days`,
  `divided_psalms`, `nt_rest_days`, `pp_segment_length`, `format_pp_segment`.
- `totals` now reports `psalms`, `psalm_readings`, `proverbs`, `proverbs_passes`,
  `proverbs_readings`, and `nt_rest_days`.

### Removed
- `PP_LONG_CHAPTER`, `PP_SPLIT_PARTS`, `PP_MIN_DAY`, `PP_DAY_TARGET` (no more merging or
  threshold-based splitting), `pp_base_portions`, `pp_cycle_length`, `format_pp`,
  `nt_days_per_pass`, `nt_second_pass_start_day`, `nt_chapters`, and `totals[:nt_chapters_read]`.
- New tuning constants are `PROVERBS_PASSES` and `PSALM_119_SECTION_SIZE`.

### Notes
- A day counts as complete when every track with content is ticked: three normally, two on the 10 NT
  rest days. Check-offs are keyed to day and track, so existing rows stay valid — but the readings
  those rows point at have changed, so anyone mid-plan is now tracking a different schedule.

## [0.7.0] — 2026-07-25

### Added
- **`config.mount_at`** — the mount path is now defined in one place, defaulting to `/daily-bread`.
  `config/routes.rb` uses `mount Bible270::Engine, at: Bible270.config.mount_at` and
  `config/initializers/omniauth.rb` uses `path_prefix Bible270.config.auth_path_prefix`, so moving
  the plan is a one-line change. Values are normalised (`"read270"`, `"/read270"`, `"/read270/"` all
  become `/read270`); nested paths and mounting at `/` are supported.
- `config.auth_path_prefix`, derived as `"<mount_at>/auth"`. An explicit
  `config.omniauth_path_prefix` still takes precedence for unusual setups.

### Changed
- The install generator defaults to `/daily-bread`, writes `config.mount_at` into the engine
  initializer, and emits a config-driven `mount` line and `path_prefix` rather than literal paths.
  `--mount-at` is still accepted to set the initial value.
- README documents the mount point in one section, including the initializer load-order caveat
  (`bible270.rb` must be read before `omniauth.rb`; alphabetical ordering makes the default naming
  work) and the two things that still need editing by hand when the path changes: OAuth callback URLs
  and any CMS links.

### Notes
- The engine's own sign-in paths are built from `request.script_name` at runtime, so they follow the
  mount point without configuration.

## [0.6.3] — 2026-07-25

### Fixed
- **`db:migrate` failed with `ActiveRecord::DuplicateMigrationNameError`.** The engine appended its
  own `db/migrate` to the host application's migration paths *and* exposed
  `bible270:install:migrations`. Using the task — the documented install step — meant every
  migration class was defined twice, once in the host's `db/migrate` and once in the gem. The engine
  no longer touches the host's migration paths; copying via the task is the single supported path,
  which also means the host owns the migrations and they appear in `schema.rb` normally.

### Added
- `spec.email` in the gemspec.

## [0.6.2] — 2026-07-24

### Changed
- Gem metadata now points at the actual repository rather than reusing the homepage:
  `source_code_uri`, `bug_tracker_uri`, and `changelog_uri` all resolve to
  <https://github.com/avonderluft/bible270>.
- `rubygems_mfa_required` is set, so pushes to rubygems.org require MFA.

### Added
- This changelog, packaged with the gem.

## [0.6.1] — 2026-07-24

### Changed
- Author and copyright now read "Andrew vonderLuft".
- The display-name-from-email example in the docs and tests uses a neutral address, since the
  algorithm can't recover internal capitals and shouldn't be shown rendering a real name wrongly.

## [0.6.0] — 2026-07-24

### Added
- **Passwordless email sign-in**, so readers without a GitHub/Google/etc. account can take part.
  A reader enters their address, receives a single-use link, and clicks it — no password anywhere
  in the gem.
  - Tokens are 256-bit and URL-safe, expire after 20 minutes (`email_sign_in_ttl`), and are stored
    **only as a SHA-256 digest**, so the table is useless to anyone reading the database.
  - Claiming a link is a conditional `UPDATE`, so a double-clicked link cannot sign in twice.
  - The "check your inbox" response is identical for known, unknown, and rate-limited addresses:
    no account enumeration and no signal that a limit was hit.
  - Rate limited per address per window (`email_sign_in_max_per_window`, `email_sign_in_window`).
  - Readers may choose the display name shown beside their reflections
    (`email_sign_in_ask_name`); otherwise it is derived from the address.
  - `Bible270::SignInToken.sweep!` clears spent and stale rows from a cron or rake task.
- `Bible270::EmailSignIn` — Rails-free module holding the normalization and token logic, so the
  security-relevant parts are unit testable on their own.
- `Bible270::SignInMailer` with text and HTML magic-link templates. The sign-in URL is built by the
  controller, so the mailer needs no `default_url_options`.
- `Bible270::Reader.from_email`, using the same identity columns as OmniAuth with `provider: "email"`,
  so every reader is treated identically downstream.
- New table: `bible270_sign_in_tokens` (migration `20260101000004`).
- `config.any_sign_in_method?`, letting views detect a deployment with no sign-in configured.

### Fixed
- `display_name_from` raised `ArgumentError` on any address containing an underscore:
  `tr("._-+", …)` was parsed as a character range. The hyphen now comes last.

### Requirements
- Email sign-in needs working Action Mailer delivery in the host application. Set
  `config.mailer_from`. Delivery is inline by default; set `email_sign_in_deliver_later` if a
  queue backend is available.

## [0.5.0] — 2026-07-24

### Added
- Built-in OmniAuth sign-in is now fully wired as the primary auth path.
- `config.omniauth_providers` accepts symbols or `[provider, label]` pairs, with labels for common
  providers and titleisation for anything custom.
- Sign-in page at `GET <mount>/sign_in` listing every configured provider.
- Sign-in controls carry the current path as `origin`, so a reader who clicks a check-off while
  signed out returns to that same day. Origins are validated as local paths only.
- `rails generate bible270:install`, which writes both initializers with OmniAuth's `path_prefix`
  already aligned to the mount point, adds the `mount` line, and prints the callback URL to register.
- `omniauth` (>= 2.0) and `omniauth-rails_csrf_protection` (>= 1.0) as runtime dependencies. Provider
  strategy gems remain the host's choice.

### Fixed
- **Sign-in was broken.** The header rendered a GET link to `/auth/github`, but OmniAuth 2.0 disabled
  GET on the request phase (CVE-2015-9284). All sign-in controls are now POST forms with CSRF tokens.
  The old link also contained a dead ternary and hardcoded the provider.
- Open-redirect hardening on the `origin` parameter: protocol-relative URLs, backslashes (which
  browsers may normalise to slashes), and auth routes are all rejected.
- `reset_session` on sign-in and sign-out, against session fixation.
- `Reader.from_omniauth` no longer assumes an `OmniAuth::AuthHash`; it tolerates plain hashes and
  missing `info`, and returns `nil` rather than raising on a malformed payload.

### Changed
- `sign_out` is `DELETE` only (previously `GET` or `DELETE`).
- Guarded actions redirect to the sign-in page instead of `request.referer`.

## [0.4.0] — 2026-07-24

### Added
- **Configurable start dates.** `config.start_date` sets a community-wide cohort date (accepting a
  `Date`, `Time`, or `"YYYY-MM-DD"` string); `config.allow_reader_start_date` controls whether
  individuals may set their own. The four combinations give undated, per-reader, community-with-
  override, and fully pinned modes.
- Readers manage their own date from the overview (`PATCH`/`DELETE <mount>/start-date`).
- Calendar mapping as pure functions on `Bible270::Plan`: `date_for`, `day_for` (clamped by default,
  `clamp: false` to detect out-of-range), `end_date_for`, `before_start?`, `after_end?`, `to_date`.
- Day pages show their calendar date with a **Today** badge; the overview gains a "Go to today" link
  and a pace indicator ("3 days behind", "right on pace", "begins in 12 days").

### Notes
- Check-offs and comments are keyed to day numbers, never dates, so changing a start date only
  re-maps the calendar — no reading history moves or is lost.
- A malformed `config.start_date` degrades to `nil` rather than raising at boot; the controller does
  reject bad input with a flash message.

## [0.3.1] — 2026-07-24

### Fixed
- **Ruby 4.0 compatibility.** Dropped the `cgi` dependency: the CGI library was removed from Ruby's
  default gems in 4.0 (only `cgi/escape` remains), so `require "cgi"` emits a deprecation warning
  there. URL escaping now uses `URI.encode_www_form_component`, which produces byte-identical output
  to `CGI.escape` and relies only on `uri`, a stable default gem.

### Added
- Regression test asserting the gem never loads the `cgi` library.
- Compatibility notes in the README: audited against the Ruby 4.0 breaking changes (`Set`/`SortedSet`,
  `Ractor`, `Net::HTTP`, `Process::Status`, `ObjectSpace`, and the gems promoted from default to
  bundled). Every file carries a `frozen_string_literal` comment and the suite passes with
  `--enable-frozen-string-literal` forced.

## [0.3.0] — 2026-07-24

### Changed — BREAKING
- **Renamed from `bible_reading_plan` to `bible270`.** Module `Bible270`, tables `bible270_*`,
  migrations `CreateBible270*`, CSS and helper prefix `b270`, install task
  `bible270:install:migrations`, mount `Bible270::Engine`. Table names changed, so this is a fresh
  install rather than an upgrade.
- **The New Testament is now read twice.** Each pass gets its own half of the plan (135 days), so
  Revelation lands on day 135 and again on day 270. Whole chapters are verse-balanced within each
  pass, tightening NT days from 11–140 verses to 20–104. The NT track now has content every day, so
  there are no rest days and all three tracks are present on all 270 days.
- **Chapters are kept whole.** Only a chapter longer than `PP_LONG_CHAPTER` (100 verses) is divided,
  which in the whole Psalter and Proverbs is Psalm 119 alone — split into exactly two readings
  (1–88, 89–176). Psalms 78 and 89 are no longer split. Short chapters merge with a neighbour, so
  Psalm 117 reads as "Psalm 116–117" rather than occupying a two-verse day.
- The Psalms/Proverbs companion resolves to exactly 135 portions, making two complete passes across
  270 days and finishing on Proverbs 31 — so all three tracks finish together at the halfway mark
  and at the end.

### Added
- `Plan.nt_days_per_pass`, `nt_second_pass_start_day`, `nt_verse_loads`, `pp_cycle_length`,
  `pp_base_portions`, and tuning constants documented in the README.

## [0.2.0] — 2026-07-24

### Changed
- **Daily portions are balanced by verse count, not chapter count**, so each day takes roughly the
  same time to read. Previously a day on Psalm 119 (176 verses) counted the same as a day on Psalm
  117 (2 verses).
- Old Testament days are grouped to be even in verses (avg ~73/day).

### Added
- `Bible270::Versification` — per-chapter verse counts for all 66 books, generated from a
  public-domain KJV text and validated against canonical anchors (1,189 chapters; Psalms 2,461
  verses; Proverbs 915; Psalm 119 = 176; Psalm 117 = 2). Verse counts are facts about the text's
  structure, so nothing copyrighted is bundled.

### Fixed
- Per-track progress bars compared days checked against *chapter* totals, so the Old Testament bar
  could never exceed ~36%. Renamed `chapters_read_in` to `days_read_in` and made the totals
  day-based.

## [0.1.0] — 2026-07-24

### Added
- Initial release: a mountable Rails engine providing a 270-day Bible reading plan with three daily
  tracks (Old Testament, New Testament, Psalms/Proverbs).
- Per-reader check-offs, public per-day reflections, a community leaderboard, and reader profiles.
- Two identity paths: built-in session sign-in, or bridging the host application's users via
  `config.current_reader_resolver` and `Reader.for_owner`.
- The schedule is pure, deterministic Ruby — no rows are stored for the plan itself; the database
  holds only readers, check-offs, and comments.

[0.9.0]: https://github.com/avonderluft/bible270/releases/tag/v0.9.0
[0.8.0]: https://github.com/avonderluft/bible270/releases/tag/v0.8.0
[0.7.0]: https://github.com/avonderluft/bible270/releases/tag/v0.7.0
[0.6.3]: https://github.com/avonderluft/bible270/releases/tag/v0.6.3
[0.6.2]: https://github.com/avonderluft/bible270/releases/tag/v0.6.2
[0.6.1]: https://github.com/avonderluft/bible270/releases/tag/v0.6.1
[0.6.0]: https://github.com/avonderluft/bible270/releases/tag/v0.6.0
[0.5.0]: https://github.com/avonderluft/bible270/releases/tag/v0.5.0
[0.4.0]: https://github.com/avonderluft/bible270/releases/tag/v0.4.0
[0.3.1]: https://github.com/avonderluft/bible270/releases/tag/v0.3.1
[0.3.0]: https://github.com/avonderluft/bible270/releases/tag/v0.3.0
[0.2.0]: https://github.com/avonderluft/bible270/releases/tag/v0.2.0
[0.1.0]: https://github.com/avonderluft/bible270/releases/tag/v0.1.0
