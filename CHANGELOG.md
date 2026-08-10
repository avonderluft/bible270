# Changelog

All notable changes to bible270. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html), treating pre-1.0 minor bumps as the place breaking changes may land.

## Unreleased Changes

See the changes since the last release:

**[Full Changelog](https://github.com/avonderluft/bible270/compare/v0.17.2...main)**

## [0.17.2] - 2026-08-08

### Added

- reader Bible translation preferences editable by admin users
- admin broadcast email tools

### Changed

- extract first and last names from OmniAuth display names
- expand CI coverage reporting and add Ruby 4.0 coverage

**[Full Changelog](https://github.com/avonderluft/bible270/compare/v0.17.1...v0.17.2)**

## [0.17.1] - 2026-08-06

### Added

- likes for reflections

### Changed

- display timestamps using the local time zone
- rename reflections to 'posts' in UI headers, because we like alliteration

**[Full Changelog](https://github.com/avonderluft/bible270/compare/v0.17.0...v0.17.1)**

## [0.17.0] - 2026-08-05

### Added

- a reflections page for browsing recent comments
- the ability for readers to edit their reflections

**[Full Changelog](https://github.com/avonderluft/bible270/compare/v0.16.1...v0.17.0)**

## [0.16.1] - 2026-08-05

### Changed

- refactor mailer URL helpers to use the engine's routes

**[Full Changelog](https://github.com/avonderluft/bible270/compare/v0.16.0...v0.16.1)**

## [0.16.0] - 2026-08-05

### Added

- threaded replies to reflections
- 'at' mention replies email notify writer of original reflection

**[Full Changelog](https://github.com/avonderluft/bible270/compare/v0.15.3...v0.16.0)**

## [0.15.3] - 2026-08-04

### Added

- `Bible270::Checkoff.reset_column_information` to migrations to prevent `UnknownAttributeError` during backfills.
- more tests (reader identity, sign-ins, and token management) to increase coverage to > 93%

### Changed

- 'Today' now derived from system time, not UTC

**[Full Changelog](https://github.com/avonderluft/bible270/compare/v0.15.2...v0.15.3)**

## [0.15.2] - 2026-08-04

### Added 

- app icon to shared header partial

### Changed

- consistent reader sort order by first name in 'People' and 'Admin'

**[Full Changelog](https://github.com/avonderluft/bible270/compare/v0.15.1...v0.15.2)**

## [0.15.1] - 2026-08-03

### Added

- CSV file with versification by day

### Changed

- refactor 'progress' and 'reflections' into partials to be more DRY
- update Coverage badge to be less cached

### Removed

- old zip file of tests

**[Full Changelog](https://github.com/avonderluft/bible270/compare/v0.15.0...v0.15.1)**

## [0.15.0] - 2026-08-02

### Added

- per-chapter checkoffs for reading with multiple chapters
- github actions for Rails CI, and Coverage reporting
- add dummy app in /test to test Rails functions with gem

### Fixed

- mobile session requiring sign-in every time: use persistent sessions using 'remember-me' cookie

**[Full Changelog](https://github.com/avonderluft/bible270/compare/v0.14.1...v0.15.0)**

## [0.14.1] - 2026-07-30

### Changed

- update Admin panel display verbage on plan run status

### Fixed

- don't display 'Today' badge unless it really is
- display 'Start' not 'Continue' if reader is on day 1
- adjust badge vertical alignment in styles

**[Full Changelog](https://github.com/avonderluft/bible270/compare/v0.14.0...v0.14.1)**

## [0.14.0] - 2026-07-30

### Added

- **Registration notices.** `config.registration_notice_emails` takes an explicit list or `:admins`
  (following `admin_emails`); off unless set. The notice names the reader, their email, how they
  signed in, when they joined and the running total, and links to their admin page when
  `config.mailer_host` is set. Hooked to reader creation rather than to a controller, so email
  sign-in, OmniAuth and bridged host users are all covered. Failures are logged, never raised —
  nobody is blocked from joining by an SMTP problem. `registration_notice_deliver_later` moves
  delivery off the request.

### Fixed

- The installer's `bible270.rb` template was missing its closing `end`, so `generate bible270:install`
  wrote an initializer that crashed the host app on boot. A test now renders every generator template
  and compiles the result, across three mount points.

**[Full Changelog](https://github.com/avonderluft/bible270/compare/v0.13.0...v0.14.0)**

## [0.13.0] — 2026-07-29

### Added

- favicon support
- admin ability to update any user's profile, including avatar
- custom footer options, to replace standard footer, or append to it

### Fixed

- Correct verb for reading prompt: 'Start' and 'Continue

**[Full Changelog](https://github.com/avonderluft/bible270/compare/v0.12.0...v0.13.0)**

## [0.12.0] — 2026-07-29

### Added

- Readers can select their preferred Bible translation in profile edit view
- Scripture links show bible version in parens

### Changed

- Top menu shows 'Progress' in place of user display name
- Dependabot gem updates to minitest and rubocop

**[Full Changelog](https://github.com/avonderluft/bible270/compare/v0.11.0...v0.12.0)**

## [0.11.0] — 2026-07-28

### Added

- **Readers can edit their own name and picture** at `<mount>/profile`, linked from the nav. An admin
  can edit anyone's from that reader's admin page. Both go through one rule (`Bible270::Names`):
  first and last required, whitespace squished, display name derived — so internal capitals and
  particles survive (`vonderLuft`, `von der Luft`). A reader who arrived via OmniAuth with only a
  display name gets the form pre-filled by splitting it.
- **Avatar uploads** — PNG, JPEG, GIF or WebP up to `config.avatar_max_bytes` (2MB), with a Remove
  button. SVG is refused, since it can carry script. Needs Active Storage in the host app; without it
  the field is hidden, the engine still loads, and avatars come from the sign-in provider as before.
  No resizing: the original is served at CSS dimensions.
- **A run can be closed to new readers** from the admin panel. Existing readers carry on signing in;
  nobody new can join. Enforced at all three points a reader can be created — the OmniAuth callback,
  issuing an email link, and consuming one. Runtime state in a new `bible270_settings` table, so it
  needs no deploy; `config.enrollment_open = false` launches closed.
- The **All 270 days** index now appears on every page, rendered from the layout rather than only on
  the overview.

### Changed

- **A returning reader needs only their email to sign in.** Names are optional on the sign-in form; a
  new reader is asked for theirs on their profile straight after clicking the link. Requiring them
  only for unknown addresses would have made the response differ between a known and an unknown one,
  which is an account-enumeration oracle — and the closed-run banner exists for the same reason.
- Closing a run says so on the sign-in page before anyone types, since the "check your inbox"
  response deliberately cannot distinguish a known address from an unknown one.

### Fixed

- Setting a reader's start date from the admin panel failed with "That doesn't look like a date"
  whenever `config.allow_reader_start_date` was off. That setting governs what a *reader* may change
  about their own plan and was wrongly gating the admin action, which now uses an ungated setter.
- The day grid ran a query per day (`read_tracks_for`), so its 270 cells cost up to 270 queries. It
  now reads the reader's single grouped count — which matters more now the grid is on every page.
- The nav's "Sign out" sat below the other items: `button_to` renders a form, and the shared
  `.b270-linkbtn` class carries a top margin, smaller font and underline meant for use under a form.
- `Bible270::Configuration` referenced `Avatars` without requiring it, so instantiating it raised
  `NameError` unless something else had already loaded avatars — which the app did by luck of require
  order and the test suite did not.

### Internal

- Tests now guard the classes of bug that bit during this run: every file under `lib/` must load on
  its own *and* survive instantiating the configuration; every setting the code calls must exist on
  `Configuration`; templates must not reference engine constants unqualified; a coloured link class
  must outrank `.b270 a`; admin actions must not use reader-gated methods; and closure must be
  enforced at all three creation points.
- Migrations: `20260101000007` (settings). Active Storage tables are the host app's
  (`bin/rails active_storage:install`).

**[Full Changelog](https://github.com/avonderluft/bible270/compare/v0.10.0...v0.11.0)** 

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

**[Full Changelog](https://github.com/avonderluft/bible270/compare/v0.9.0...v0.10.0)**

## [0.9.0] — 2026-07-25

### Changed

* The New Testament now has a reading every day — no days off.
* The daily total is now 76–175 verses (was 76–203), averaging ~119.

### Added

* Shared division machinery used by both the NT and the Psalms: `Plan.divide_to_fill`, `expand_readings`, `segment_length`, `format_segment`, `divided`.
* `Plan.nt_parts`, `nt_readings`, `nt_chapters`, `divided_nt_chapters`, `psalm_chapters`.
* `totals` reports `nt_readings` (270) and `nt_divided` (10).

### Removed

* `Plan.nt_groups`, `format_pp_segment`, `pp_segment_length` (superseded by the shared `format_segment` and `segment_length`), and `totals[:nt_rest_days]`.
* `nt_rest_days` remains but now always returns an empty array.

**[Full Changelog](https://github.com/avonderluft/bible270/compare/v0.6.2...v0.9.0)**

## [0.6.2] — 2026-07-25

This is the initial public release.

### Added

* Initial release of a mountable Rails engine providing a 270-day Bible reading plan with three daily tracks: Old Testament, New Testament, and Psalms/Proverbs.
* Per-reader check-offs, public per-day reflections, a community leaderboard, and reader profiles.
* Two identity paths: built-in session sign-in, or bridging the host application's users via `config.current_reader_resolver` and `Reader.for_owner`.
* A pure, deterministic Ruby schedule; the database stores readers, check-offs, and comments rather than plan rows.
* `Bible270::Versification`, providing per-chapter verse counts for all 66 books, generated from a public-domain KJV text and validated against canonical anchors.
* Verse-balanced daily portions rather than chapter-count balancing, so daily reading time is approximately even.
* Per-track progress bars based on days read rather than chapter totals.
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
* Compatibility notes and tests covering Ruby 4.0 changes, including removal of the `cgi` dependency.

### Changed

* The project was renamed from `bible_reading_plan` to `bible270`, including the `Bible270` module, database tables, migrations, CSS and helper prefixes, install task, and engine name.
* The install generator defaults to `/daily-bread`, writes the mount path into the engine initializer, and emits configuration-driven `mount` and `path_prefix` lines.
* The engine's sign-in paths follow the mount point at runtime through `request.script_name`.
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

### Requirements

* Email sign-in requires working Action Mailer delivery in the host application. Set `config.mailer_from`; delivery is inline by default, or set `email_sign_in_deliver_later` when a queue backend is available.

[0.17.2]: https://github.com/avonderluft/bible270/releases/tag/v0.17.2
[0.17.1]: https://github.com/avonderluft/bible270/releases/tag/v0.17.1
[0.17.0]: https://github.com/avonderluft/bible270/releases/tag/v0.17.0
[0.16.1]: https://github.com/avonderluft/bible270/releases/tag/v0.16.1
[0.16.0]: https://github.com/avonderluft/bible270/releases/tag/v0.16.0
[0.15.3]: https://github.com/avonderluft/bible270/releases/tag/v0.15.3
[0.15.2]: https://github.com/avonderluft/bible270/releases/tag/v0.15.2
[0.15.1]: https://github.com/avonderluft/bible270/releases/tag/v0.15.1
[0.15.0]: https://github.com/avonderluft/bible270/releases/tag/v0.15.0
[0.14.1]: https://github.com/avonderluft/bible270/releases/tag/v0.14.1
[0.14.0]: https://github.com/avonderluft/bible270/releases/tag/v0.14.0
[0.13.0]: https://github.com/avonderluft/bible270/releases/tag/v0.13.0
[0.12.0]: https://github.com/avonderluft/bible270/releases/tag/v0.12.0
[0.11.0]: https://github.com/avonderluft/bible270/releases/tag/v0.11.0
[0.10.0]: https://github.com/avonderluft/bible270/releases/tag/v0.10.0
[0.9.0]: https://github.com/avonderluft/bible270/releases/tag/v0.9.0
[0.6.2]: https://github.com/avonderluft/bible270/releases/tag/v0.6.2
