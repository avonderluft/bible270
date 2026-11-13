# Changelog

Notable changes, following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Release comparisons are linked below.

## [Unreleased]

### Added

- preview original avatar photos after a 3-second hover; keep touch behavior unchanged
- show random, theme-matched Scripture frames on a 3-second bread-icon hover or immediately by tap, click, or keyboard
- manage Scripture texts in Admin; custom texts supplement YAML defaults with automatic translation credits
- support custom quotations with **Author / source**, without Bible translation credits
- enable or disable default Scripture texts without changing YAML; choices persist across runs
- start new runs with fresh admin memberships, alumni status for other readers, and open enrollment; preserve accounts, history, and discussions
- revert post-upgrade restarts to saved memberships, calendars, and enrollment settings; preserve both runs' progress and discussions
- add collapsible Active/Alumni lists, quick **Make Active** buttons, and read-only run history; remember active-list visibility for the tab's sign-in session
- let configured Site-admins grant or revoke admin access; roles persist independently of run membership

### Changed

- show a random frame on day completion, with an optional dove, synchronized fade, and reduced-motion support
- improve the bread icon, title alignment, and small-screen Papyrus layout
- simplify frame dismissal and remove lingering bread-icon focus outlines
- let alumni use Community and discussions; retain shared reflections and frozen progress
- exclude alumni from current-group notices and reminders; retain opted-in personal notices and admin broadcasts
- keep separate progress and consistency history for each run
- speed up tests with CPU-aware workers, focused suites, and quieter logs
- compact reader controls and replace the completion-animation checkbox with an Enable/Disable button
- simplify custom-text forms; require pasted text while API lookup is deferred
- consolidate Scripture management in Admin, with inline actions and custom passages first in biblical order
- compact name fields and reorder Admin/Profile controls

**Upgrade:** Back up the host database, then copy and run migrations `20260101000024`–`20260101000027`. Existing progress becomes the first run; the run-history migration is irreversible.

### Fixed

- fix iPhone completion rendering and fade the dove without a final flash
- hide collapsed Scripture passages immediately; restore previews on fresh hover or focus
- always confirm reader removal before deleting progress and reflections
- align Admin, Site-admin, and Alumni badges with compact, theme-matched styling
- shorten theme and upload hints on Admin and Profile; keep the System hint on one line
- avoid repeated calendar lookups when rendering the day grid

## [1.15.1] - 2026-11-06

### Fixed

- standardize dropdown arrows, spacing, keyboard focus, and disabled styling across reflections, filters, Profile, and Admin; keep header theme and reminder-time selectors compact

## [1.15.0] - 2026-11-06

### Added

- show Community progress bars and completed-day counts to signed-in readers, including non-admin preview; keep alphabetical order and admin-only management links and schedule details
- use muted, theme-matched bar colors, including warm tan for Cedar, with at least 3:1 fill-to-track contrast
- mark today on each reader's active schedule with a thin line, tooltip, and accessible day description; omit markers for undated, future, and ended schedules

Counts include only fully completed days and use one query. Visitor listings are unchanged; no migration is required.

## [1.14.0] - 2026-11-06

### Added

- add **View as non-admin** for the current session: hide admin details and actions but keep the Admin tab to switch back. Personal check-offs and reflections still work; roles and other sessions are unchanged.

### Changed

- shorten the consistency explanation and show it only when sorting by Consistency ranking; keep reader consistency details on every sort
- align both view-toggle buttons to the right of the Admin label on the same row
- shorten the README and changelog while retaining setup instructions, upgrade warnings, and release links

## [1.13.5] - 2026-11-02

### Changed

- keep Psalm 73 whole and divide Psalm 69 into verses 1–19 and 20–36
- repeat Psalm 1 on day 270, keeping its day-one reading and Proverbs 11's three readings; Proverbs 31 finishes on day 269
- add previews of all six themes to the README

**Schedule impact:** Compared with 1.13.3, Psalms/Proverbs assignments change on days 112–113 and 117–270. Existing day-based check-offs are not remapped.

## [1.13.3] - 2026-10-30

### Fixed

- move Moonlight's Hebrew and Greek reflections with their text, preserving ripple effects, scenery, and mobile behavior

## [1.13.2] - 2026-10-30

### Fixed

- center Hebrew and Greek background text in the side margins on displays 1200px and wider; preserve mobile positioning and visibility

### Changed

- update test dependencies to RuboCop 1.91.x and SimpleCov 1.2.x

## [1.13.1] - 2026-10-29

### Changed

- show consistency scores, on-track/ahead percentages, day counts, rank status, and the scoring explanation for every Admin reader sort

### Fixed

- display negative consistency scores as `0` without changing the underlying ranking calculations or order
- suppress expected libvips warnings in malformed-image tests without hiding unexpected output or changing production logging

## [1.13.0] - 2026-10-28

### Added

- add Admin Consistency ranking: average end-of-day scores of 100 on track, +5 per day ahead (up to seven days), and −10 per day behind
- show scores, on-track/ahead percentages, and evaluated-day counts; list provisional readers (fewer than seven days) after established rankings, then unranked readers
- add a Rank column to Reader Stats for consistency sorting, with shared ranks for ties (e.g. `1, 1, 1, 4`) and a dash for unranked readers
- derive scores from completion timestamps and current schedules, excluding today, pre-enrollment dates, and dates after the plan ends; changing check-offs or start dates can change past scores

### Changed

- replace Rails 7.1 with Rails 7.2 in the Ruby 3.2 CI matrix entry
- shorten the avatar backfill summary to “Originals retained.” and align its test expectation

## [1.12.0] - 2026-10-22

### Fixed

- load avatars promptly without forced asynchronous decoding or extra per-reader database queries
- retry failed avatars up to twice; refresh expired upload redirects without changing signed provider URLs
- show accessible initials when avatars fail, including cached failures and images added during navigation or conversations
- preserve the previous picture and profile settings when upload processing or storage fails, and remove both original and thumbnail attachments when a picture is removed
- prevent conflicting avatar changes during simultaneous uploads and backfills; retain file records for cleanup retries if storage deletion fails

### Added

- optimize uploads as 256×256 center-cropped WebP avatars at quality 85, correcting orientation, converting to sRGB, preserving transparency, and stripping metadata; animated images use the first frame
- retain original photos and display thumbnails only after processing and storage succeed; do not process images during page loads
- validate image data with a 40-megapixel limit and the configurable upload limit (2 MiB by default)
- add `bible270:avatars:optimize` with metadata-only `DRY_RUN=1`, `FORCE=1`, `BATCH_SIZE`, safe reruns, and protection against concurrent picture changes
- report backfill counts and before/after display sizes; continue after individual failures but exit nonzero if any fail

### Security

- validate PNG chunk structure and checksums, discard text metadata before native decoding, and limit expanded PNG color profiles to 4 MiB
- prevent redundant Active Storage analysis of retained originals from bypassing the sanitized image-processing pipeline

**Upgrade:** Install libvips with PNG, JPEG, GIF and WebP support on upload/backfill hosts. The gem adds `image_processing` and `ruby-vips`; hosts using Active Storage need no new migration. Run the backfill from the host Rails app after deployment. Existing uploads display originals until optimized; provider images are unchanged.

Originals are retained, so optimization saves bandwidth, not storage. Uploads and backfills must run outside an existing database transaction to avoid leftover files after rollback.

## [1.11.1] - 2026-10-22

### Changed

- simplify artwork on phone-sized screens: hide decorative scripture and word reflections, lower landscape scenes, and reduce fine detail while preserving desktop artwork
- further mute Ocean's mobile colors and wave lines while keeping the shoreline and gulls
- use a soft moonlight reflection on phones and retain opaque foreground trees in the simplified Forest scene
- draw Forest trees as direct SVG paths with explicit green fills instead of reused SVG instances
- increase the space between the app title and compact theme selector

### Fixed

- declare the color scheme before rendering and keep it synchronized during theme changes and navigation
- request `color-scheme: only light` for Papyrus, Meadow, and Ocean while preserving System's device-following behavior

Browser website-darkening features can still override theme colors. In iOS Brave, disabling Night Mode resolved the reported darkened light themes and white Forest trees.

## [1.11.0] - 2026-10-22

### Added

- add Meadow and Ocean light themes alongside Papyrus, Cedar, Forest, and Moonlight
- add muted artwork for each theme: textured papyrus with ragged edges and curled corners, a sunrise meadow, an afternoon coast with gulls, cedar grain, layered forest silhouettes, and a moonlit lake
- add shared Hebrew and Greek scripture backgrounds, with rippled reflections in Moonlight
- add a compact theme selector beside the app title on every signed-in page

### Changed

- save and apply theme selections immediately from the header, Profile, and Admin without submitting unrelated edits
- synchronize controls for the same reader while keeping an admin's own theme independent of another reader's setting
- use short theme names, list light themes first, and retain Light/Dark descriptions in Profile and Admin
- keep the header and theme selector compact on desktop and mobile without wrapping navigation
- let System follow the device appearance using Papyrus for light and Cedar for dark, including their artwork

### Fixed

- restore the previous theme selection and show an error when saving fails; prevent overlapping saves for the same reader

Existing saved theme preferences are preserved; no additional migration is required for installations with display preferences already enabled.

## [1.10.2] - 2026-10-18

### Changed

- show each Admin reader row in that reader's selected theme, with matching text and link colors
- let System-themed rows follow the viewing browser's light or dark preference

## [1.10.1] - 2026-10-18

### Added

- let admins set each reader's theme

### Changed

- show last activity with 24-hour time and keep completed-day passages in the Day link tooltip
- link reader emails and move Remove picture beside the upload controls on Admin reader pages
- move translation settings below Name and picture, followed by Theme and Email notifications

## [1.10.0] - 2026-10-18

### Added

- add Forest and Midnight themes; rename Light and Dark to Parchment and Earth

### Changed

- move Remove picture beside the Profile upload controls
- reduce avatar queries and defer offscreen avatar loading
- close the mobile menu on outside clicks or Escape
- show the plan's time zone beside reminder settings
- improve screen-reader labels for reflection reading selectors

### Fixed

- leave profile settings and pictures unchanged when a profile update is invalid
- warn when a reflection draft cannot be saved in the browser
- isolate test uploads between parallel workers and remove them after testing

## [1.9.1] - 2026-10-16

### Fixed

- keep the mobile menu icon readable in light and dark themes, including on iOS

## [1.9.0] - 2026-10-15

### Added

- let readers choose Light, Dark, or System in Profile, with System as the default
- add a warm brown dark palette while keeping the completion dove bright

Upgrading hosts must install and run the new reader display-preference migration.

## [1.8.5] - 2026-09-27

### Changed

- show likes and replies on My Progress and reader pages, with admin edit links on reader pages
- show each reader's pace beside their completed-day count for admins on Community
- add edit, like, and reply controls to reflections on Admin reader pages

### Fixed

- align like and reply controls across reflection listings

## [1.8.4] - 2026-09-25

### Changed

- show start date, completed days, and ahead/behind status together in the Admin reader list

## [1.8.3] - 2026-09-21

### Changed

- keep Proverbs 7 whole and divide Proverbs 10 and 16 into four readings

## [1.8.1] - 2026-09-19

### Changed

- add a Today link and shorter introduction to Community
- allow readers to edit recent reflections from My Progress
- open the day grid by default on reader and Profile pages
- move Admin completions below translation settings

## [1.8.0] - 2026-09-18

### Added

- let readers add named YouTube videos to reflections and replies with on-demand playback

## [1.7.3] - 2026-09-17

### Changed

- show each reader's last activity date in Reader Stats and `bible270:readers:list`

## [1.7.2] - 2026-09-17

### Changed

- link reader emails and recent-activity days in Admin
- show each activity day's readings on hover

## [1.7.1] - 2026-09-17

### Added

- sort Admin readers and Reader Stats by most or least recent activity

## [1.7.0] - 2026-09-17

### Added

- show each reader's latest reading activity in Admin
- show Blue Letter Bible Scripture popups in reflections and previews using each reader's selected translation

## [1.6.2] - 2026-09-14

### Fixed

- keep Markdown lists compact despite blank lines between items, in previews and reflections

## [1.6.1] - 2026-09-14

### Added

- let admins edit any reflection or reply inline without changing its author or ordinary-reader permissions

### Changed

- select list placeholders on insertion and continue bullet/numbered lists on Enter

### Fixed

- safely link pasted HTTP(S) URLs in previews and reflections, preserving explicit Markdown links and trailing punctuation

## [1.6.0] - 2026-09-14

### Added

- add Admin reader sorting by first name, last name, and most/least completed days, plus a dismissible Reader Stats report using the selected sort
- let admin broadcasts target either every reader with an email address or only readers recognized as administrators

### Changed

- send broad reflection/reply notices once using BCC; keep personal reply and mention notices individually addressed
- expand tests for registration delivery, legacy names, custom footers, mentions, and completion-animation settings after migrations

### Fixed

- handle boolean defaults consistently across Rails 7.1–8.1 during migration reconciliation and testing

## [1.5.1] - 2026-09-11

### Added

- add `bible270:notifications:enable_all` to opt existing readers into all reflection/reply emails and report the result
- add `bible270:readers:list` to print aligned Name, Days Read, and schedule Status columns, ordered by completed days

### Changed

- default new readers to emails for every new reflection and reply; migration `20260101000022` changes only the default and preserves existing reader preferences

## [1.5.0] - 2026-09-07

### Added

- add Markdown formatting and previews for reflections/replies, including formatted emails, mentions, and browser drafts; existing plain text is unchanged. **Upgrade:** copy and run the `body_format` comment migration.

### Changed

- update RuboCop and SimpleCov development dependencies and replace deprecated SimpleCov configuration methods
- use the current Coveralls-backed Shields.io coverage badge endpoint for the `main` branch

### Fixed

- keep `json` below 3.0 while supported Rails releases still pass positional parse options, preventing session-cookie decoding from crashing every request under `json` 3.0

## [1.4.2] - 2026-09-03

### Added

- let admins disable each reader's completion dove without affecting progress. **Upgrade:** copy and run the `completion_dove_disabled` migration before using this setting.

### Changed

- keep the completion dove bright in dark mode, enlarge it to fit 80% of the screen, smooth its outline, and finish with a centered fade
- show every reader who finished a day after the Reflections section, using compact 56px avatars ordered from earliest to latest completion

### Fixed

- show the dove once per saved day completion, even with simultaneous check-offs, repeated responses, or session retries

## [1.4.1] - 2026-09-02

### Changed

- animate the completion dove from the lower center after saving, without a pause between submission and response
- improve installer guidance for OmniAuth providers, deferred bundling, Active Storage, pending migrations, and OAuth callback setup
- detect existing engine mounts more reliably and move them above catch-all routes when necessary

### Fixed

- reject invalid enrollment states and malformed or out-of-range admin day values instead of silently interpreting them
- apply admin profile name and avatar changes atomically, preventing partial updates when validation fails
- report broadcast queueing, delivery failures, and partial success accurately without recording an entirely failed broadcast as sent
- restrict reflection return redirects to safe application URLs
- honor the installer's `--mailer-from` option and reject or safely quote unsafe configuration values

## [1.4.0] - 2026-09-02

### Added

- show a nonblocking dove animation on the final checkoff, with Turbo/HTML fallback and reduced-motion support, replacing the generic success message

### Changed

- refine the completion animation to 1.6 seconds with smoother easing, limit checkoff transitions to relevant visual properties, and make reduced-motion transitions effectively instantaneous

### Fixed

- accept repeated or simultaneous check-off requests without duplicate-record errors

## [1.3.2] - 2026-09-02

### Fixed

- silently recover all Turbo interactions from stale sessions, retry once with a fresh CSRF token, and reload rather than submit with a known-stale token if refreshing fails

## [1.3.1] - 2026-09-01

### Fixed

- correct Day 27's New Testament reading to include Matthew 26:75

## [1.3.0] - 2026-08-29

### Added

- add Bible.com as the first-listed and default reader/admin Scripture source for every offered translation, using chapter links and WLC Hebrew or THGNT Greek when `HEB/GRK` is selected; existing reader choices are preserved
- add `ALLGRK — LXX OT and Greek NT` immediately after `HEB/GRK`, using Blue Letter Bible's mGNT/LXX routing or Bible.com's GRCBRENT Old Testament and THGNT New Testament

## [1.2.0] - 2026-08-28

### Added

- let readers and admins choose all reflection/reply emails, only personal replies/mentions, or none; preserve existing preferences and explain pending migrations
- suggest up to five unambiguous reader handles when a signed-in writer types `@`, with keyboard and touch selection; server-side mention checks are unchanged

### Fixed

- refresh stale `Reader` column information after an in-process database migration so newly available reflection email controls do not remain hidden until the web process restarts

## [1.1.7] - 2026-08-27

### Fixed

- recover checkoffs from expired/rotated sessions without a flash or 422 page: refresh remembered sessions and CSRF tokens, then retry once if needed

## [1.1.6] - 2026-08-25

### Changed

- show linked completed-day counts only to admins on Community, with gold hover/focus styling; skip the progress query for other viewers

## [1.1.5] - 2026-08-25

### Changed

- keep Bible270 open while using one Scripture tab for Bible Gateway and Blue Letter Bible: desktop browsers reuse the existing tab, while iOS Safari replaces its background tab so each click reliably switches to the reading
- use one Scripture-link helper for daily readings and Reflections, preserving safe links without JavaScript

### Removed

- remove the unused `passage_url_builder` configuration hook; Bible Gateway and Blue Letter Bible are now the intentionally fixed passage providers

## [1.1.4] - 2026-08-24

### Added

- let administrators persistently override the current run start date, see which readers are affected, and reset to the configured date without changing check-offs or reflections

### Changed

- link reader avatars in Admin to the same reader-management pages as their names
- show a signed-in reader's effective plan start date beside Home progress without repeating it on My Progress
- increase the default parallel test workers to six while retaining `PARALLEL_WORKERS` for constrained systems

## [1.1.3] - 2026-08-23

### Changed

- align Profile reminder choices with the recommended 15-minute scheduler interval while preserving existing off-quarter preferences
- document concrete host cron and Docker Compose setup, output logging, verification, and one-scheduler-per-database guidance

## [1.1.2] - 2026-08-22

### Changed

- include complete 1.1.0 and 1.1.1 release history in the packaged changelog

### Fixed

- make the mobile navigation menu toggle reliably on iOS Safari with an explicit accessible button, synchronized `aria-expanded` state, and controlled menu visibility

## [1.1.1] - 2026-08-22

### Changed

- replace the first custom mobile-menu handler with native `details` disclosure behavior

## [1.1.0] - 2026-08-22

### Changed

- notify reflection authors directly about replies, share one opt-out with explicit mentions, and stop inserting handles into reply text
- consolidate duplicate visitor sign-in prompts on day pages into one invitation
- show “Finish what you started” on My Progress only when partially read days need attention
- clarify the global day-index control as “View all 270 days” and use that standard collapsed control on My Progress and public reader pages
- redirect successful Profile updates back to Profile
- simplify Community listings to linked reader names and avatars with full joined dates instead of progress counts
- remove account-specific reflection messaging from the signed-out Progress page
- simplify header, Reflections, and empty day-page framing while retaining the primary actions and information

### Removed

- remove the Compact reading preference so daily reading pages have one simple, predictable presentation
- replace the homepage reader preview with one clear link to the Community page
- remove the redundant schedule-restart shortcut from progress recovery choices
- remove reader-facing start-date status, controls, and self-service endpoints while retaining automatic and admin-managed personal calendars
- remove weekly progress, its unused schedule helper, milestones, and explanatory schedule-recovery copy from My Progress
- replace the Reflections page’s separate day grid with the standard “View all 270 days” control

## [1.0.0] - 2026-08-20

### Added

- optional daily reading reminders with per-reader opt-in and delivery time, reminder emails, and a scheduler-friendly Rake task
- immediate day-completion feedback with a preserved next-day or Progress action
- actionable Progress sections for unfinished portions, the current calendar week, milestones, and schedule recovery without losing reading or reflection history
- browser-local reflection and reply drafts, day and author filters, pagination, and new-activity markers on the Reflections page
- a remembered compact reading mode that keeps passages, checkoffs, navigation, and completion next steps in focus
- run `test` with two workers by default, showing live progress, combined results and coverage, and recorded runtimes; offer `test:serial` as an alternative

### Changed

- replace progress-ranked community lists with transparent recent-participation and alphabetical views that emphasize reading together
- show why each reader appears in Reading together, including their latest reading, reflection, or join activity
- add consistent pending, success, and retry feedback to reading, like, reflection, and reply actions, with repeat-safe checkoff and like requests
- improve accessibility with AA text contrast, visible keyboard focus, descriptive day-grid labels, clear day navigation, touch-friendly tooltips, responsive forms, and reduced-motion support
- replace the reminder time field with aligned hour and minute selectors and an accessible time-zone tooltip
- hide personal start-date controls and calendar prompts when the community configuration does not allow readers to change dates

### Fixed

- keep profiles and scheduled reminder jobs available while a newly installed daily-reminder database migration is pending

## [0.19.0] - 2026-08-17

### Added

- shared responsive navigation with clearer Community, Reflections, My Progress, and Profile labels plus a mobile menu

### Changed

- align page headings with navigation destinations and clarify the Start or Continue reading and Go to today actions
- always email explicitly mentioned readers, including the original reflection author when a reply prefills their mention
- normalize packaged file permissions before gem builds

### Removed

- the per-reader mention-email opt-out; writing a reader's name explicitly now always sends the mention notice

## [0.18.2] - 2026-08-15

### Added

- Young's Literal Translation (`YLT`) as a Bible Gateway and Blue Letter Bible reading option

### Changed

- summarize reflection likes with one heart and a count, with all liker names displayed in a one-name-per-row tooltip
- keep the reflection heart red while at least one like remains

## [0.18.1] - 2026-08-12

### Changed

- increase reader avatar sizes across community, profile, admin, and reflection views

## [0.18.0] - 2026-08-10

### Added

- `HEB/GRK` reading option with WLC links for the Old Testament, Psalms, and Proverbs, and mGNT links for the New Testament
- per-reader Bible Gateway or Blue Letter Bible source selection in Profile, with the same control available to admins
- `bible270:migrations:reconcile` task to safely align copied Bible270 and Active Storage schemas with local migration versions

### Changed

- original-language reading labels now display `Hebrew` or `Greek` for the relevant passage
- passage-source preferences use an extensible string value, defaulting to Bible Gateway and preserving earlier Blue Letter Bible selections during migration

## [0.17.2] - 2026-08-08

### Added

- reader Bible translation preferences editable by admin users
- admin broadcast email tools

### Changed

- extract first and last names from OmniAuth display names
- expand CI coverage reporting and add Ruby 4.0 coverage

## [0.17.1] - 2026-08-06

### Added

- likes for reflections

### Changed

- display timestamps using the local time zone
- rename reflections to Posts in UI headers

## [0.17.0] - 2026-08-05

### Added

- a reflections page for browsing recent comments
- the ability for readers to edit their reflections

## [0.16.1] - 2026-08-05

### Changed

- refactor mailer URL helpers to use the engine's routes

## [0.16.0] - 2026-08-05

### Added

- threaded replies to reflections
- 'at' mention replies email notify writer of original reflection

## [0.15.3] - 2026-08-04

### Added

- `Bible270::Checkoff.reset_column_information` to migrations to prevent `UnknownAttributeError` during backfills.
- more tests (reader identity, sign-ins, and token management) to increase coverage to > 93%

### Changed

- 'Today' now derived from system time, not UTC

## [0.15.2] - 2026-08-04

### Added

- app icon to shared header partial

### Changed

- consistent reader sort order by first name in 'People' and 'Admin'

## [0.15.1] - 2026-08-03

### Added

- CSV file with versification by day

### Changed

- refactor 'progress' and 'reflections' into partials to be more DRY
- update Coverage badge to be less cached

### Removed

- old zip file of tests

## [0.15.0] - 2026-08-02

### Added

- per-chapter checkoffs for reading with multiple chapters
- github actions for Rails CI, and Coverage reporting
- add dummy app in /test to test Rails functions with gem

### Fixed

- mobile session requiring sign-in every time: use persistent sessions using 'remember-me' cookie

## [0.14.1] - 2026-07-30

### Changed

- clarify Admin run-status wording

### Fixed

- don't display 'Today' badge unless it really is
- display 'Start' not 'Continue' if reader is on day 1
- adjust badge vertical alignment in styles

## [0.14.0] - 2026-07-30

### Added

- add registration notices for all sign-in methods via `config.registration_notice_emails` (address list or `:admins`; off by default). Include reader details, counts, and an admin link when `mailer_host` is set. Failed delivery never blocks registration; `registration_notice_deliver_later` enables queued delivery.

### Fixed

- restore the installer's missing closing `end`, which caused host boot failures; test generated Ruby at three mount points

## [0.13.0] - 2026-07-29

### Added

- favicon support
- admin ability to update any user's profile, including avatar
- custom footer options, to replace standard footer, or append to it

### Fixed

- use the correct reading prompt: Start or Continue

## [0.12.0] - 2026-07-29

### Added

- Readers can select their preferred Bible translation in profile edit view
- Scripture links show bible version in parens

### Changed

- Top menu shows 'Progress' in place of user display name
- Dependabot gem updates to minitest and rubocop

## [0.11.0] - 2026-07-28

### Added

- let readers edit their name and picture at `<mount>/profile`, and admins edit any reader. Require first/last names, trim spacing, preserve capitalization, and prefill OmniAuth names.
- accept removable PNG, JPEG, GIF and WebP avatars up to `config.avatar_max_bytes` (2MB); reject SVG. Uploads require host Active Storage. Otherwise use provider avatars. This release serves originals without resizing.
- let admins close enrollment while existing readers can still sign in. Enforce closure at all email and OmniAuth creation points; store it in `bible270_settings`. Use `config.enrollment_open = false` to launch closed.
- show the All 270 days index on every page

### Changed

- require only an email to sign in; ask new readers for names after they follow the link. Keep responses identical for known and unknown addresses to prevent account enumeration.
- show closed enrollment on the sign-in page before submission, preserving the generic inbox response

### Fixed

- allow admins to change start dates when reader-managed dates are disabled
- replace up to 270 day-grid queries with one grouped count
- align Sign out with the other navigation items
- require `Avatars` before configuration uses it, preventing load-order-dependent `NameError`

### Internal

- test library loading, configuration, view constants, CSS, admin permissions, and enrollment closure
- add settings migration `20260101000007`; install host Active Storage tables with `bin/rails active_storage:install`

## [0.10.0] - 2026-07-26

### Reading plan

- read Proverbs once instead of twice; split longer chapters at discourse boundaries in 1–9 and 30–31, evenly elsewhere
- keep Psalms of 25 verses or fewer whole (`PSALM_WHOLE_MAX_VERSES`); split longer Psalms at turns of thought
- keep divided chapters on consecutive days and balance Psalms/Proverbs together by verse load
- read the New Testament once over 270 days, splitting long chapters at content boundaries
- validate custom `CHAPTER_BREAKS`; use `[]` to keep a chapter whole. Host overrides reload without restart via `config.chapter_breaks` or YAML at `config.chapter_breaks_path`. Precedence: constant < config < file.

### Features

- add interactive `bin/rails generate bible270:install` for mounting, authentication, initializers, and migrations; support scripted setup with `--defaults`
- centralize route and OmniAuth mount paths in `config.mount_at`
- add single-use email sign-in links with SHA-256 token storage and account-enumeration protection; require first/last names
- support shared and personal start dates, Today badges, and pace indicators; changing dates preserves day-number check-offs
- add `/admin`, gated by `admin_emails` or `admin_resolver` (404 if unauthorized), to remove readers, set progress, and adjust calendars
- publish reflections immediately; let admins hide them reversibly or delete them from reader pages or a visible/hidden filterable list

### Fixed

- use CSRF-protected POST forms for OmniAuth 2.0+, reject unsafe return paths, and reset sessions on sign-in/out
- prevent duplicate migration names by using copied migrations only
- qualify engine constants in views and include helpers when using a host parent controller
- fix dark-on-dark buttons caused by CSS precedence
- fix generated OmniAuth path configuration and avoid credential loading that could block boot
- prevent nested HTML layouts in sign-in emails
- remove the `cgi` dependency for Ruby 4.0 compatibility
- normalize blank reflection tracks to NULL before validation
- let `email_sign_in_log_link` use nil to log in development/test, true to always log, or false to never log. Record delivery outcomes without exposing them in responses.
- test that all used configuration accessors exist

### Notes

- Table names changed from `bible_reading_plan_*` in the 0.9.0 line; this is a fresh install.

## [0.9.0] - 2026-07-25

### Changed

- The New Testament now has a reading every day — no days off.
- The daily total is now 76–175 verses (was 76–203), averaging ~119.

### Added

- Shared division machinery used by both the NT and the Psalms: `Plan.divide_to_fill`, `expand_readings`, `segment_length`, `format_segment`, `divided`.
- `Plan.nt_parts`, `nt_readings`, `nt_chapters`, `divided_nt_chapters`, `psalm_chapters`.
- `totals` reports `nt_readings` (270) and `nt_divided` (10).

### Removed

- `Plan.nt_groups`, `format_pp_segment`, `pp_segment_length` (superseded by the shared `format_segment` and `segment_length`), and `totals[:nt_rest_days]`.
- `nt_rest_days` remains but now always returns an empty array.

## [0.6.2] - 2026-07-25

This is the initial public release.

### Added

- a mountable Rails engine with a verse-balanced, 270-day Old Testament, New Testament, and Psalms/Proverbs plan
- reader check-offs, public daily reflections, a community leaderboard, profiles, and day-based progress bars
- a deterministic Ruby schedule and `Bible270::Versification` counts for all 66 books, derived from public-domain KJV text; no stored plan rows
- shared/personal start dates, Today links, pace indicators, and calendar helpers: `date_for`, `day_for`, `end_date_for`, `before_start?`, `after_end?`, `to_date`
- configurable OmniAuth providers or host-user bridging via `current_reader_resolver` and `Reader.for_owner`
- email sign-in with optional display names, rate limiting, account-enumeration protection, and single-use 256-bit tokens expiring after 20 minutes; store only SHA-256 digests
- email sign-in APIs: `SignInToken.sweep!`, Rails-free `EmailSignIn`, text/HTML `SignInMailer`, `Reader.from_email`, `any_sign_in_method?`, and the `bible270_sign_in_tokens` table
- `rails generate bible270:install` for initializers, mounting, OmniAuth paths, and callback URLs
- centralized `mount_at` (default `/daily-bread`) and derived `auth_path_prefix`, supporting nested paths and `/`; sign in at `GET <mount>/sign_in`
- gem contact/repository metadata and Ruby 4.0 compatibility tests

### Changed

- The project was renamed from `bible_reading_plan` to `bible270`, including the `Bible270` module, database tables, migrations, CSS and helper prefixes, install task, and engine name.
- The install generator defaults to `/daily-bread`, writes the mount path into the engine initializer, and emits configuration-driven `mount` and `path_prefix` lines.
- The engine's sign-in paths follow the mount point at runtime through `request.script_name`.
- The display-name-from-email example uses a neutral address.
- `sign_out` is `DELETE` only.
- Guarded actions redirect to the sign-in page.
- URL escaping uses `URI.encode_www_form_component` rather than `CGI.escape`.

### Fixed

- prevent `DuplicateMigrationNameError`: use `bible270:install:migrations` to copy migrations rather than also appending engine migration paths
- Sign-in was broken under OmniAuth 2.0 because the request phase no longer permits GET requests. Sign-in controls now use POST forms with CSRF tokens.
- Open redirects through the `origin` parameter, including protocol-relative URLs, backslashes, and authentication routes.
- Session fixation by resetting the session on sign-in and sign-out.
- `Reader.from_omniauth` now tolerates plain hashes, missing `info`, and malformed payloads without raising.
- `display_name_from` no longer raises `ArgumentError` for addresses containing underscores.
- Ruby 4.0 compatibility issues caused by the removed `cgi` default gem.
- Progress bars that could not reach the correct totals because they compared checked days with chapter totals.

### Requirements

- Email sign-in requires working Action Mailer delivery in the host application. Set `config.mailer_from`; delivery is inline by default, or set `email_sign_in_deliver_later` when a queue backend is available.

[Unreleased]: https://github.com/avonderluft/bible270/compare/v1.15.1...main
[1.15.1]: https://github.com/avonderluft/bible270/compare/v1.15.0...v1.15.1
[1.15.0]: https://github.com/avonderluft/bible270/compare/v1.14.0...v1.15.0
[1.14.0]: https://github.com/avonderluft/bible270/compare/v1.13.5...v1.14.0
[1.13.5]: https://github.com/avonderluft/bible270/compare/v1.13.3...v1.13.5
[1.13.3]: https://github.com/avonderluft/bible270/compare/v1.13.2...v1.13.3
[1.13.2]: https://github.com/avonderluft/bible270/compare/v1.13.1...v1.13.2
[1.13.1]: https://github.com/avonderluft/bible270/compare/v1.13.0...v1.13.1
[1.13.0]: https://github.com/avonderluft/bible270/compare/v1.12.0...v1.13.0
[1.12.0]: https://github.com/avonderluft/bible270/compare/v1.11.1...v1.12.0
[1.11.1]: https://github.com/avonderluft/bible270/compare/v1.11.0...v1.11.1
[1.11.0]: https://github.com/avonderluft/bible270/compare/v1.10.2...v1.11.0
[1.10.2]: https://github.com/avonderluft/bible270/compare/v1.10.1...v1.10.2
[1.10.1]: https://github.com/avonderluft/bible270/compare/v1.10.0...v1.10.1
[1.10.0]: https://github.com/avonderluft/bible270/compare/v1.9.1...v1.10.0
[1.9.1]: https://github.com/avonderluft/bible270/compare/v1.9.0...v1.9.1
[1.9.0]: https://github.com/avonderluft/bible270/compare/v1.8.5...v1.9.0
[1.8.5]: https://github.com/avonderluft/bible270/compare/v1.8.4...v1.8.5
[1.8.4]: https://github.com/avonderluft/bible270/compare/v1.8.3...v1.8.4
[1.8.3]: https://github.com/avonderluft/bible270/compare/v1.8.1...v1.8.3
[1.8.1]: https://github.com/avonderluft/bible270/compare/v1.8.0...v1.8.1
[1.8.0]: https://github.com/avonderluft/bible270/compare/v1.7.3...v1.8.0
[1.7.3]: https://github.com/avonderluft/bible270/compare/v1.7.2...v1.7.3
[1.7.2]: https://github.com/avonderluft/bible270/compare/v1.7.1...v1.7.2
[1.7.1]: https://github.com/avonderluft/bible270/compare/v1.7.0...v1.7.1
[1.7.0]: https://github.com/avonderluft/bible270/compare/v1.6.2...v1.7.0
[1.6.2]: https://github.com/avonderluft/bible270/compare/v1.6.1...v1.6.2
[1.6.1]: https://github.com/avonderluft/bible270/compare/v1.6.0...v1.6.1
[1.6.0]: https://github.com/avonderluft/bible270/compare/v1.5.1...v1.6.0
[1.5.1]: https://github.com/avonderluft/bible270/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/avonderluft/bible270/compare/v1.4.2...v1.5.0
[1.4.2]: https://github.com/avonderluft/bible270/compare/v1.4.1...v1.4.2
[1.4.1]: https://github.com/avonderluft/bible270/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/avonderluft/bible270/compare/v1.3.2...v1.4.0
[1.3.2]: https://github.com/avonderluft/bible270/compare/v1.3.1...v1.3.2
[1.3.1]: https://github.com/avonderluft/bible270/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/avonderluft/bible270/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/avonderluft/bible270/compare/v1.1.7...v1.2.0
[1.1.7]: https://github.com/avonderluft/bible270/compare/v1.1.6...v1.1.7
[1.1.6]: https://github.com/avonderluft/bible270/compare/v1.1.5...v1.1.6
[1.1.5]: https://github.com/avonderluft/bible270/compare/v1.1.4...v1.1.5
[1.1.4]: https://github.com/avonderluft/bible270/compare/v1.1.3...v1.1.4
[1.1.3]: https://github.com/avonderluft/bible270/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/avonderluft/bible270/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/avonderluft/bible270/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/avonderluft/bible270/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/avonderluft/bible270/compare/v0.19.0...v1.0.0
[0.19.0]: https://github.com/avonderluft/bible270/compare/v0.18.3...v0.19.0
[0.18.3]: https://github.com/avonderluft/bible270/compare/v0.18.2...v0.18.3
[0.18.2]: https://github.com/avonderluft/bible270/compare/v0.18.1...v0.18.2
[0.18.1]: https://github.com/avonderluft/bible270/compare/v0.18.0...v0.18.1
[0.18.0]: https://github.com/avonderluft/bible270/compare/v0.17.2...v0.18.0
[0.17.2]: https://github.com/avonderluft/bible270/compare/v0.17.1...v0.17.2
[0.17.1]: https://github.com/avonderluft/bible270/compare/v0.17.0...v0.17.1
[0.17.0]: https://github.com/avonderluft/bible270/compare/v0.16.1...v0.17.0
[0.16.1]: https://github.com/avonderluft/bible270/compare/v0.16.0...v0.16.1
[0.16.0]: https://github.com/avonderluft/bible270/compare/v0.15.3...v0.16.0
[0.15.3]: https://github.com/avonderluft/bible270/compare/v0.15.2...v0.15.3
[0.15.2]: https://github.com/avonderluft/bible270/compare/v0.15.1...v0.15.2
[0.15.1]: https://github.com/avonderluft/bible270/compare/v0.15.0...v0.15.1
[0.15.0]: https://github.com/avonderluft/bible270/compare/v0.14.1...v0.15.0
[0.14.1]: https://github.com/avonderluft/bible270/compare/v0.14.0...v0.14.1
[0.14.0]: https://github.com/avonderluft/bible270/compare/v0.13.1...v0.14.0
[0.13.1]: https://github.com/avonderluft/bible270/compare/v0.13.0...v0.13.1
[0.13.0]: https://github.com/avonderluft/bible270/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/avonderluft/bible270/compare/v0.11.2...v0.12.0
[0.11.2]: https://github.com/avonderluft/bible270/compare/v0.11.1...v0.11.2
[0.11.1]: https://github.com/avonderluft/bible270/compare/v0.11.0...v0.11.1
[0.11.0]: https://github.com/avonderluft/bible270/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/avonderluft/bible270/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/avonderluft/bible270/compare/v0.6.2...v0.9.0
[0.6.2]: https://github.com/avonderluft/bible270/releases/tag/v0.6.2
