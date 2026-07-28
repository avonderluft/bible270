# Changelog

All notable changes to bible270. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html), treating pre-1.0 minor bumps as the place breaking changes may land.

## Unreleased Changes

See the changes since the last release:

**[Full Changelog](https://github.com/avonderluft/bible270/compare/v0.10.0...main)**

## [0.10.0] — 2026-07-26

### Reading plan
- **Proverbs is read once**, not twice, and its longer chapters are divided — at the discourse
  boundaries in chapters 1–9 and 30–31, evenly elsewhere, since 10–29 are collections of
  independent sayings.
- **A psalm of 25 verses or fewer is never divided** (`PSALM_WHOLE_MAX_VERSES`), which keeps 131 of
  the 150 psalms whole. Psalms over 25 verses break at their turns of thought.
- **A divided chapter is always read on consecutive days.** Nothing is inserted between the parts of
  a split psalm.
- Psalms and Proverbs are now divided against a single budget, so the two books balance by verse
  load rather than each being squeezed into a fixed number of days.
- The New Testament is read once with a reading every day: 260 chapters over 270 days, so the
  longest are divided (at content boundaries via `CHAPTER_BREAKS`, e.g. Luke 1 at the annunciations,
  Magnificat and Benedictus).
- `CHAPTER_BREAKS` lets any chapter's break points be set by hand, or `[]` to force it whole. Break
  points are validated; a bad entry raises rather than silently overlapping.
- Break points can also come from the host app and be changed **without restarting**:
  `config.chapter_breaks`, or a YAML file at `config.chapter_breaks_path` re-read whenever it
  changes. Precedence: constant < config < file.

### Features
- **Interactive installer** — `bin/rails generate bible270:install` asks where to mount, which
  sign-in methods to enable, writes the initializers, adds the `mount` line, copies the migrations
  and runs them. Scriptable with `--defaults` and friends.
- **`config.mount_at`** — the mount path in one place; routes and OmniAuth both read it.
- **Passwordless email sign-in** with single-use magic links; only a SHA-256 digest is stored, and
  the response never reveals whether an address exists. First and last name are required.
- **Configurable start dates** — community-wide or per reader, with a Today badge and a pace
  indicator. Check-offs are keyed to day numbers, so changing a date never moves history.
- **Admin panel** (`/admin`, gated by `config.admin_emails` or `config.admin_resolver`; unauthorised
  requests 404 rather than 403). Remove readers, set their progress exactly (mark complete through a
  day, or toggle individual days), and move them to a given day of the plan — which re-maps the
  calendar only, since check-offs are keyed to day numbers.
- **Comment moderation.** Reflections are **visible as soon as they are written** — moderation is for
  taking something down afterwards, not gatekeeping every post. An admin can hide a reflection
  (removing it from the day and community pages while keeping the writer's words, reversibly) or
  delete it outright, from a list filterable by visible/hidden or from the writer's own page.

### Fixed
- Sign-in was broken: OmniAuth 2.0+ rejects GET on its request phase, so the controls are now POST
  forms with CSRF tokens. Open-redirect hardening on the return-to path, and `reset_session` on
  sign-in and sign-out.
- `db:migrate` failed with `DuplicateMigrationNameError` — the engine both appended its migrations
  to the host's paths and shipped `install:migrations`.
- Views raised `uninitialized constant Plan`: a template's lexical scope is `Object`, so engine
  constants must be fully qualified.
- Views raised `undefined method 'b270_*'`: Rails only auto-includes an engine's helpers when the
  controller's superclass is exactly `ActionController::Base`, which it isn't once
  `config.parent_controller` points at the host.
- Buttons rendered dark-on-dark: `.b270 a{color:inherit}` outranked `.b270-btn`.
- The generated OmniAuth initializer called `path_prefix`, which `OmniAuth::Builder` does not
  define, and read credentials at boot so a bad master key stopped the app starting.
- The sign-in email was rendered inside the host's mailer layout, nesting one HTML document in
  another.
- Ruby 4.0 compatibility: dropped `cgi`, removed from default gems in 4.0.
- Posting a reflection about the whole day failed with "Track is not included in the list": the
  form's blank option submits an empty string, which `allow_nil` rejects. Blank tracks are now
  normalised to NULL before validation.

- `config.email_sign_in_log_link` — tri-state: nil logs the sign-in link in development and test
  only, true forces it on (for smoke-testing a production build locally before mail is wired up),
  false disables it. The log also distinguishes sent, rate-limited and failed delivery, which the
  response deliberately cannot.
- A test asserts every setting the code calls is actually defined on `Configuration`, so a missing
  accessor fails the suite instead of raising `NoMethodError` on whichever request touches it.

### Notes
- Table names changed from `bible_reading_plan_*` in the 0.9.0 line; this is a fresh install.

## [0.9.0] — 2026-07-25

**[Full Changelog](https://github.com/avonderluft/bible270/compare/v0.6.2...v0.9.0)**

### Changed

* **The New Testament now has a reading every day — no days off.** 260 chapters over 270 days is reconciled by dividing the 10 longest chapters in two: Luke 1, Matthew 26 and 27, Mark 14, Luke 9, 12 and 22, John 6 and 8, and Acts 7. Luke 1 reads as 1–40 then 41–80. This drops the longest NT reading from 80 verses to 58 (stdev 14.6 → 11.4) and removes the 10 rest days from 0.8.0, so all three tracks are present on all 270 days and every day needs three check-offs.
* The daily total is now 76–175 verses (was 76–203), averaging ~119.

### Added

* Shared division machinery used by both the NT and the Psalms: `Plan.divide_to_fill`, `expand_readings`, `segment_length`, `format_segment`, `divided`.
* `Plan.nt_parts`, `nt_readings`, `nt_chapters`, `divided_nt_chapters`, `psalm_chapters`.
* `totals` reports `nt_readings` (270) and `nt_divided` (10).

### Removed

* `Plan.nt_groups`, `format_pp_segment`, `pp_segment_length` (superseded by the shared `format_segment` and `segment_length`), and `totals[:nt_rest_days]`.
* `nt_rest_days` remains but now always returns an empty array.

## [0.6.2] — 2026-07-25

This is the initial public release.

### Added

* Initial release of a mountable Rails engine providing a 270-day Bible reading plan with three daily tracks: Old Testament, New Testament, and Psalms/Proverbs.
* Per-reader check-offs, public per-day reflections, a community leaderboard, and reader profiles.
* Two identity paths: built-in session sign-in, or bridging the host application's users via `config.current_reader_resolver` and `Reader.for_owner`.
* A pure, deterministic Ruby schedule; the database stores readers, check-offs, and comments rather than plan rows.
* `Bible270::Versification`, providing per-chapter verse counts for all 66 books, generated from a public-domain KJV text and validated against canonical anchors.
* Verse-balanced daily portions rather than chapter-count balancing, so daily reading time is approximately even.
* Old Testament days grouped to be even in verses, averaging approximately 73 verses per day.
* Per-track progress bars based on days read rather than chapter totals.
* The New Testament read twice, with each pass occupying half of the 270-day plan. Whole chapters are verse-balanced within each pass.
* A Psalms/Proverbs companion plan resolving to exactly 135 portions, making two complete passes across the 270-day plan.
* Chapters are generally kept whole; Psalm 119 is divided into two readings, while shorter chapters may be combined with a neighboring psalm.
* Configurable start dates through `config.start_date` and `config.allow_reader_start_date`, including per-reader date management.
* Calendar mapping functions on `Bible270::Plan`: `date_for`, `day_for`, `end_date_for`, `before_start?`, `after_end?`, and `to_date`.
* Calendar-aware day pages, including a **Today** badge, a **Go to today** link, and a pace indicator.
* Built-in OmniAuth sign-in as the primary authentication path.
* Configurable OmniAuth providers, including labels for common providers and titleisation for custom providers.
* A sign-in page at `GET <mount>/sign_in`.
* `rails generate bible270:install`, which creates the initializers, adds the engine mount, configures OmniAuth's path prefix, and prints the callback URL.
* Passwordless email sign-in using single-use magic links.
* Secure email sign-in tokens that are 256-bit, URL-safe, expire after 20 minutes, and are stored only as SHA-256 digests.
* Rate limiting for email sign-in attempts and protection against account enumeration.
* Optional reader-selected display names for email sign-in.
* `Bible270::SignInToken.sweep!` for clearing spent and stale tokens.
* `Bible270::EmailSignIn`, a Rails-free module containing the normalization and token logic.
* `Bible270::SignInMailer` with text and HTML magic-link templates.
* `Bible270::Reader.from_email`, using the same identity columns as OmniAuth with `provider: "email"`.
* The `bible270_sign_in_tokens` table.
* `config.any_sign_in_method?`.
* A centralized `config.mount_at` setting, defaulting to `/daily-bread`, with derived `config.auth_path_prefix`.
* Support for nested mount paths and mounting at `/`.
* Configuration-driven engine mounting and OmniAuth path prefixes.
* `spec.email` in the gemspec.
* Gem metadata pointing to the actual repository for `source_code_uri`, `bug_tracker_uri`, and `changelog_uri`.
* RubyGems MFA requirement through `rubygems_mfa_required`.
* This changelog, packaged with the gem.
* Compatibility notes and tests covering Ruby 4.0 changes, including removal of the `cgi` dependency.

### Changed

* The project was renamed from `bible_reading_plan` to `bible270`, including the `Bible270` module, database tables, migrations, CSS and helper prefixes, install task, and engine name.
* The install generator defaults to `/daily-bread`, writes the mount path into the engine initializer, and emits configuration-driven `mount` and `path_prefix` lines.
* The README documents the mount point, initializer load-order requirements, OAuth callback URLs, and CMS links that may need updating when the mount path changes.
* The engine's sign-in paths follow the mount point at runtime through `request.script_name`.
* Author and copyright information now read “Andrew vonderLuft”.
* The display-name-from-email example uses a neutral address.
* `sign_out` is `DELETE` only.
* Guarded actions redirect to the sign-in page.
* URL escaping uses `URI.encode_www_form_component` rather than `CGI.escape`.

### Fixed

* **`db:migrate` failed with `ActiveRecord::DuplicateMigrationNameError`.** The engine appended its own `db/migrate` to the host application's migration paths and also exposed `bible270:install:migrations`. Using the task meant every migration class was defined twice. The engine no longer touches the host's migration paths; copying via the task is the single supported path.
* Sign-in was broken under OmniAuth 2.0 because the request phase no longer permits GET requests. Sign-in controls now use POST forms with CSRF tokens.
* Open redirects through the `origin` parameter, including protocol-relative URLs, backslashes, and authentication routes.
* Session fixation by resetting the session on sign-in and sign-out.
* `Reader.from_omniauth` now tolerates plain hashes, missing `info`, and malformed payloads without raising.
* `display_name_from` no longer raises `ArgumentError` for addresses containing underscores.
* Ruby 4.0 compatibility issues caused by the removed `cgi` default gem.
* Progress bars that could not reach the correct totals because they compared checked days with chapter totals.

### Breaking Changes

* The project was renamed from `bible_reading_plan` to `bible270`; this is a fresh install rather than an in-place upgrade because database table names changed.
* The New Testament schedule changed from a single pass to two verse-balanced passes.
* The Psalms/Proverbs schedule changed to two complete 135-portion passes.
* Calendar and reading-plan behavior is based on day numbers rather than stored plan rows.

### Requirements

* Email sign-in requires working Action Mailer delivery in the host application. Set `config.mailer_from`; delivery is inline by default, or set `email_sign_in_deliver_later` when a queue backend is available.

[0.10.0]: https://github.com/avonderluft/bible270/releases/tag/v0.10.0
[0.9.0]: https://github.com/avonderluft/bible270/releases/tag/v0.9.0
[0.6.2]: https://github.com/avonderluft/bible270/releases/tag/v0.6.2
