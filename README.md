# Bible 270

[![Rails CI](https://github.com/avonderluft/bible270/actions/workflows/railsci.yml/badge.svg)](https://github.com/avonderluft/bible270/actions/workflows/railsci.yml) [![Test Coverage](https://img.shields.io/coverallsCoverage/github/avonderluft/bible270?branch=main&cacheSeconds=300)](https://coveralls.io/github/avonderluft/bible270?branch=main) [![Gem Version](https://img.shields.io/gem/v/bible270)](https://rubygems.org/gems/bible270) [![Downloads](https://img.shields.io/gem/dt/bible270)](https://rubygems.org/gems/bible270) [![GitHub Release Date - Published_At](https://img.shields.io/github/release-date/avonderluft/bible270?label=last%20release&color=seagreen)](https://github.com/avonderluft/bible270/releases)

A mountable **Rails engine** for a 270-day (9-month) Bible reading plan. Readers check off readings, share reflections, and follow one another's progress.

Created for [Kingdom Movement School of Ministry](https://www.kmsm.life/) and designed to work with [ComfyMiddleSeat](https://github.com/avonderluft/comfy-middle-seat) CMS, it also works in other Rails apps.

See the [architecture walkthrough](docs/architecture.md) for implementation details and the [changelog](CHANGELOG.md) for release history.

## The plan

Three tracks every day, balanced by **verse count**:

- **Old Testament** — once through Genesis–Malachi, excluding Psalms and Proverbs.
- **New Testament** — once through, with longer chapters divided to fill 270 days.
- **Psalms & Proverbs** — once each, interleaved over days 1–269, then **Psalm 1 again on day 270**. Proverbs 31 finishes on day 269; Proverbs occupies 91 days.

By default, psalms of 25 verses or fewer stay whole. Longer chapters use selected breaks or balanced divisions; **Psalm 73 stays whole**, **Psalm 69 splits into verses 1–19 and 20–36**, and **Psalm 119 has eleven 16-verse readings** (two acrostic stanzas each). Parts of a divided chapter always fall on consecutive days. See [Tuning the plan](#tuning-the-plan) for overrides.

The Old Testament and Revelation 22 finish on day 270 alongside Psalm 1. Daily readings average about 115 verses (range 76–166).

`Bible270::Plan` generates the schedule deterministically from `Bible270::Versification`; the schedule is not stored in the database. **Progress and reflections are public.**

## Requirements

- **Ruby >= 3.2** and a **Rails >= 7.2** host app. CI covers selected combinations through Ruby 4.0 / Rails 8.1; check your host's dependencies before upgrading Ruby.
- Turbo JavaScript for check-offs without a page reload. The gem includes `turbo-rails`; ordinary HTML forms remain available without JavaScript.
- For picture uploads and backfills: **Active Storage** and **libvips** with PNG, JPEG, GIF, and WebP support on every upload/backfill host. Install libvips with, for example, `sudo apt-get install libvips-tools` on Ubuntu or `sudo pacman -S libvips` on Arch. The gem supplies `image_processing` and `ruby-vips`; native processing loads only when optimizing an image, not when displaying existing or provider avatars.

JavaScript controls show pending, success, and retry feedback. Repeated check-off and like requests converge on the requested state rather than reversing it.

## Install

Run installation commands from the **host Rails application**.

```ruby
# Gemfile
gem "bible270"
```

<details>
<summary>Other sources</summary>

Use one of these instead:

```ruby
gem "bible270", git: "https://github.com/avonderluft/bible270.git", branch: "main"
gem "bible270", path: "<path_to_your_local_copy>/bible270"
```
</details>

```bash
bundle install
bin/rails generate bible270:install
```

The interactive generator:

1. Chooses the mount path and email/OmniAuth sign-in methods.
2. Adds known OmniAuth strategy gems and offers to bundle them.
3. Offers to install Active Storage for avatars, copies migrations, and offers to run them.
4. Writes `config/initializers/bible270.rb` and, for social sign-in, `omniauth.rb`.
5. Adds `mount Bible270::Engine, at: Bible270.config.mount_at` to your routes.

Defaults use `/daily-bread` with email and GitHub sign-in. **You must still configure mail delivery, provider credentials, and OAuth callback URLs** as listed by the generator. Migrations run before the initializers are written.

Copied migrations belong to your app. The engine does not also add its migration directory to your app's migration paths.

For non-interactive setup:

```bash
bin/rails generate bible270:install --defaults \
  --mount-at=/daily-bread --providers=github,google_oauth2 \
  --mailer-from=no-reply@example.org --no-migrate
```

| Flag | Effect |
|------|--------|
| `--defaults` | Skip prompts; use supplied options and defaults |
| `--mount-at=PATH` | Mount path (default `/daily-bread`) |
| `--providers=a,b` | OmniAuth providers; `--providers=` for none |
| `--email` / `--no-email` | Enable or disable email sign-in |
| `--mailer-from=ADDR` | From address for sign-in emails |
| `--bundle` / `--no-bundle` | Run or skip bundling added strategy gems |
| `--migrate` / `--no-migrate` | Run or skip migrations |
| `--active-storage` / `--no-active-storage` | Install or skip missing Active Storage tables |

Re-running skips existing strategy gems and reuses the engine mount, moving it above catch-all routes if needed. Rails prompts before overwriting an initializer. If you skip bundling or migrations, complete them before using the affected features.

<details>
<summary>Manual installation</summary>

```ruby
# config/initializers/bible270.rb
Bible270.configure do |config|
  config.mount_at = "/daily-bread"
  config.email_sign_in = true
  config.mailer_from = "no-reply@example.com"
  config.omniauth_providers = [] # email only; see Authentication for OmniAuth
end
```

```ruby
# config/routes.rb — before catch-all routes
mount Bible270::Engine, at: Bible270.config.mount_at
```

```bash
bin/rails bible270:install:migrations
bin/rails db:migrate
```

For picture uploads, also enable and install Active Storage if missing:

```bash
bin/rails active_storage:install
bin/rails db:migrate
```

Configure Action Mailer delivery and, if needed, [OmniAuth](#social-sign-in).
</details>

### Upgrading

No generator re-run is needed:

```bash
bundle update bible270
bin/rails bible270:install:migrations # skips existing copies
bin/rails db:migrate
```

Review the [changelog](CHANGELOG.md) before deploying. Copy and run **all current migrations**, not just those for a feature you use; feature-specific migration notes appear below.

**Schedule changes do not remap existing day-based check-offs.** Compared with 1.13.3, the current default Psalms/Proverbs assignments differ on days 112–113 and 117–270, including the closing Psalm 1 reading. Review the effect on an active group before upgrading.

### Reconciling a copied database

A copied database may already contain the tables but have migration versions that differ from your app's timestamped copies. Preview reconciliation first:

```bash
bin/rails bible270:migrations:reconcile
```

The task recognizes Bible270 migrations and the related generated Active Storage migration by name, then checks tables, columns, indexes, and foreign keys. An existing table alone is not sufficient. **Review the preview and back up the database** before applying:

```bash
APPLY=1 bin/rails bible270:migrations:reconcile
bin/rails db:migrate
```

Preview writes nothing. Apply only records verified local versions in `schema_migrations`; it does not alter application tables. Missing changes remain pending for `db:migrate`.

## Mount point

Set the path in one place:

```ruby
# config/initializers/bible270.rb
Bible270.configure do |config|
  config.mount_at = "/daily-bread"
end
```

Routes use `mount_at`; OmniAuth uses `Bible270.config.auth_path_prefix` (`"<mount_at>/auth"`). Engine sign-in links use `request.script_name` at runtime. `"read270"`, `"/read270"`, and `"/read270/"` normalize to `/read270`; nested paths and `/` also work.

When moving the mount, update **provider-dashboard OAuth callback URLs** and **CMS links** manually. Set `config.omniauth_path_prefix` only if OmniAuth needs a separate path.

> **Load order matters:** `bible270.rb` must load before `omniauth.rb`. Rails' alphabetical initializer order handles these names. If you rename them, preserve that order or set `mount_at` in `config/application.rb`.

## Authentication

Use passwordless **email links**, **OmniAuth social sign-in**, or both. Set `omniauth_providers = []` for email-only or `email_sign_in = false` for social-only. Reading is public; participation requires a reader account by default.

### Email links

Configure working Action Mailer delivery and a permitted sender address:

```ruby
Bible270.configure do |config|
  config.email_sign_in = true
  config.mailer_from = "no-reply@example.com"
  config.email_sign_in_ask_name = true
  config.email_sign_in_require_name = true   # first and last name
  # config.email_sign_in_ttl = 20 * 60       # link lifetime in seconds
  # config.email_sign_in_max_per_window = 5  # requests per address
  # config.email_sign_in_window = 15 * 60
  # config.email_sign_in_deliver_later = true # requires an Active Job worker
end
```

- Tokens are 256-bit, URL-safe, single-use, and expire after 20 minutes by default. Conditional updates prevent double claims.
- Only a **SHA-256 token digest** is stored, not the raw token or a password. Token records still contain personal data such as email addresses.
- Valid-address requests receive the same “Check your inbox” response whether known, unknown, or rate-limited, avoiding disclosure through that message.
- Names come from the reader, falling back to the email address (`mary.anne.smith@…` → “Mary Anne Smith”). Email readers use `provider: "email"` in the same identity model as OmniAuth readers.
- Schedule `Bible270::SignInToken.sweep!` to remove expired or consumed records older than seven days by default.

### Social sign-in

The installer adds known strategy gems, writes the initializer, and prints callback URLs to register, such as `https://example.com/daily-bread/auth/github/callback`. The gem already includes `omniauth` and `omniauth-rails_csrf_protection`.

To add a provider manually, install its strategy gem, list it in `config.omniauth_providers`, and register it with OmniAuth:

```ruby
# config/initializers/omniauth.rb
Rails.application.config.middleware.use OmniAuth::Builder do
  # Applies to providers declared below; Builder has no path_prefix method.
  options path_prefix: Bible270.config.auth_path_prefix
  provider :github, ENV["GITHUB_CLIENT_ID"], ENV["GITHUB_CLIENT_SECRET"]
end

OmniAuth.config.on_failure = proc { |env| Bible270::SessionsController.action(:failure).call(env) }
```

```ruby
# config/initializers/bible270.rb
Bible270.configure do |config|
  config.mount_at = "/daily-bread"
  config.omniauth_providers = [:github] # or [:github, [:google_oauth2, "Google"]]
  config.parent_controller = "::ApplicationController"
end
```

**Sign-in must POST with a CSRF token** to `<mount>/auth/:provider`. The engine uses `button_to`; do the same for custom controls. OmniAuth 2 rejects GET sign-in to address [CVE-2015-9284](https://nvd.nist.gov/vuln/detail/CVE-2015-9284).

The engine accepts only local return paths and resets the session on sign-in and sign-out to prevent session fixation. It stores provider, uid, name, email, and avatar URL, not OAuth access tokens or passwords.

### Use your own users

Set a resolver to use host authentication instead of the engine's reader-session lookup:

```ruby
config.current_reader_resolver = lambda do |controller|
  user = controller.send(:current_user)
  next nil unless user
  Bible270::Reader.for_owner(user, display_name: user.try(:name) || user.email,
                             email: user.try(:email), avatar_url: user.try(:avatar_url))
end
```

`Reader.for_owner` links any host model polymorphically. CMS administrator authentication is separate from public-reader authentication; email or OmniAuth is usually simpler for public visitors.

## Admin panel

The panel at `<mount>/admin` returns **404** unless you explicitly authorize administrators:

```ruby
config.admin_emails = %w[andrew@example.org]
# or
config.admin_resolver = ->(reader) { reader.email.to_s.end_with?('@example.org') }
```

Authorized readers get an Admin link. **View as non-admin** hides admin-only details and disables admin actions for the current session. You stay signed in as yourself; your check-offs and reflections still work. The Admin tab remains available with **Return to admin view**. This does not change roles or affect other sessions, and signing in again restores admin view.

The panel supports:

- Sorting readers by name, completed days, activity, or consistency, with **Reader Stats** following the selected sort.
- Changing reader profiles, themes, and notification preferences. Another reader's theme does not change your own.
- Moving a reader to a day by adjusting their start date; check-offs remain tied to day numbers.
- Setting progress exactly through day N, **clearing completions after N**, or toggling individual days.
- Removing a reader **and all their check-offs and reflections**.
- Moderating reflections at `<mount>/admin/comments`: hide reversibly or delete. Reflections are public immediately, without prior approval.
- Sending individually addressed broadcasts to all readers with email addresses or only administrators.

To print a progress report ordered by completed days:

```bash
docker compose exec -e RAILS_ENV=production rails bin/rails bible270:readers:list
```

The report shows completed days, last activity, and calendar status: on track, ahead, behind, or undated.

### Consistency ranking

Consistency is the average end-of-day score on a dated schedule:

`100 + 5 × min(days ahead, 7) − 10 × days behind`

A score of 100 is an average on-track baseline, not a percentage. Negative scores display as `0` but retain their true value for ranking. Scores, on-track/ahead percentages, and evaluated-day counts appear for every Admin sort; sorting by consistency also shows the scoring explanation and adds a **Rank** column to Reader Stats.

- Evaluation runs from the later of plan start or account creation through the earlier of yesterday or plan end, in the plan's time zone. Late enrollment does not reset the scheduled day.
- A day counts when all required readings are checked off, using the latest check-off timestamp. Early completions carry forward; today's catch-up does not improve previous evenings.
- Readers with seven or more evaluated evenings rank first, then **Provisional** readers with one to six, then **Not ranked** readers with none.
- Within each ranked group, ordering uses unrounded score, on-track/ahead percentage, and evaluated days. Equal metrics share competition ranks (`1, 1, 1, 4`); name and ID order ties. Unranked readers show a dash.

This is **reconstructed history, not an audit log**. Rechecking readings, bulk progress edits, or start-date changes can alter scores. Timestamps record when completion was entered, not necessarily when reading occurred. No snapshot job or additional migration is required.

## Reflections and notifications

The Reflections page groups conversations by their latest approved reply, with day/author filters, pagination, and activity indicators since the reader's previous visit.

Drafts stay in the current browser for up to **30 days** and clear after a successful post. If storage is blocked or full, a warning appears but posting still works. On shared devices, clear browser storage to remove saved drafts.

Typing `@` offers up to five unambiguous reader handles; manual mentions work without JavaScript. **Formatting** opens tools for bold, italic, quotations, lists, links, and YouTube videos. **Preview** uses the same server-side sanitizer as posted content. Existing reflections remain literal plain text until deliberately converted; without the `body_format` migration (`20260101000021`), the composer falls back to plain text.

When `config.mention_notifications` is enabled, readers can choose email for every new reflection/reply, only direct replies and mentions, or none. Admins can change the same preference. Broad notices use BCC; direct notices are individually addressed.

Migration `20260101000018` adds broad notifications without changing existing choices; `20260101000022` makes them the default for new readers only. Follow [Upgrading](#upgrading) to install these and the visit-tracking migration (`20260101000017`).

To **override every existing reader's preference** with “Every new reflection and reply”:

```bash
bin/rails bible270:notifications:enable_all
```

With Docker Compose:

```bash
docker compose exec -e RAILS_ENV=production rails bin/rails bible270:notifications:enable_all
```

### YouTube videos

The **Video** button accepts YouTube watch, share (`youtu.be`), Shorts, live, and embed URLs, plus an optional name. It inserts a marked Markdown link in its own paragraph:

```markdown
[YouTube video](https://www.youtube.com/watch?v=aB3_dE-fG12 "bible270-video")
```

Preview and posted content show **View video**, or **View video ‘Name’**. No remote thumbnail or player loads until the reader requests playback. The player uses `www.youtube-nocookie.com` without autoplay; **loading it shares the reader's IP address and request metadata with YouTube**. Privacy-enhanced mode is not anonymous playback.

An **Open on YouTube** link remains available without JavaScript or when embedding is blocked. It opens a new tab with `rel="nofollow ugc noopener"`. Notification emails use ordinary links and preserve the optional name. Unmarked or unsupported links stay links; start times and playlist parameters are not retained. No API key, upload support, extra gem, or additional migration is needed.

For a host Content Security Policy, add `https://www.youtube-nocookie.com` to the existing **`frame-src`** directive. Do not replace the policy or allow arbitrary frames. Custom engine layouts must also render `bible270/shared/video_embeds` once alongside the other shared scripts.

## Themes

Choose **Papyrus**, **Meadow**, or **Ocean** for light themes; **Cedar**, **Forest**, or **Moonlight** for dark themes; or **System** to follow the device (Papyrus/Cedar). System is the default for visitors and new readers.

Signed-in readers can choose a theme beside the app title or under **Profile → Theme**. Header, Profile, and Admin selections save immediately with JavaScript; without it, use Save. Older installations need migration `20260101000023`; see [Upgrading](#upgrading).

![Papyrus](images/papyrus.png "Papyrus")
![Meadow](images/meadow.png "Meadow")
![Ocean](images/ocean.png "Ocean")
![Cedar](images/cedar.png "Cedar")
![Forest](images/forest.png "Forest")
![Moonlight](images/moonlight.png "Moonlight")

Custom layouts must render the shared styles and set the `.b270` element's `data-display-mode` to `current_reader&.effective_display_mode || 'system'`.

## Start dates

The plan can be **undated** (day numbers only) or **dated**:

```ruby
config.start_date = Date.new(2026, 9, 6) # Date, Time, or "YYYY-MM-DD"; nil = no shared date
config.allow_reader_start_date = true
```

| `start_date` | `allow_reader_start_date` | Behavior |
|---|---|---|
| nil | true *(default)* | Personal start date set on first check-off; admins can adjust it |
| a date | true | Shared date unless an admin assigns a personal date |
| a date | false | Shared date for everyone; stored personal dates ignored |
| nil | false | Fully undated |

Dated plans show dates, a **Today** badge, and a “Go to today” link. Admins can override the shared `config.start_date` without deploying, or reset it to the configured value. Shared-date changes immediately remap dates, Today, and reminders for readers on that calendar. Personal calendars can also be adjusted. **Check-offs and reflections stay tied to day numbers.**

Date helpers work without Rails:

```ruby
Bible270::Plan.date_for(1, "2026-09-06")          # => Sun, 06 Sep 2026
Bible270::Plan.end_date_for("2026-09-06")         # => Wed, 02 Jun 2027 (day 270)
Bible270::Plan.day_for(Date.current, start)       # clamped to 1..270
Bible270::Plan.day_for(date, start, clamp: false) # may return -3 or 271
Bible270::Plan.before_start?(date, start)
```

## Daily reading reminders

Reminders require both host enablement and reader opt-in; both default to off. Readers choose a time in Profile (default `08:00`, quarter-hour choices). Existing off-quarter times remain available until changed. Times use the **plan's time zone**, shown in Profile, not the device's zone.

```ruby
# config/initializers/bible270.rb
Bible270.configure do |config|
  config.daily_reminders = true
  config.mailer_from = "no-reply@yourdomain.com"
  config.mailer_host = "yourdomain.com" # day/profile links
  # config.time_zone = "America/Los_Angeles" # nil follows the server's clock
end
```

Install the reminder migration (`20260101000016`) via [Upgrading](#upgrading). Bible270 does **not** install a scheduler. Run this task every 15 minutes using your host's cron, platform scheduler, or recurring-job system:

```bash
bin/rails bible270:reminders:send
```

For cron, run `crontab -e` as the application account and use absolute paths:

```cron
*/15 * * * * cd /absolute/path/to/application && RAILS_ENV=production bin/rails bible270:reminders:send >> /absolute/path/to/application/log/bible270-reminders.log 2>&1
```

For Docker Compose, use `pwd` in the Compose directory and `command -v docker` to find the paths. Run cron as an account with Docker access:

```cron
*/15 * * * * cd /absolute/path/to/application && /usr/bin/docker compose exec -T rails bin/rails bible270:reminders:send >> /absolute/path/to/application/log/bible270-reminders.log 2>&1
```

`-T` disables the interactive terminal that cron cannot provide. Verify with `crontab -l` and check the log after the next interval. **Run one scheduler per database**, not one per web container.

The task sends inline with `deliver_now` on the first run at or after the chosen local time and records the sent date only after successful delivery. It skips readers already sent that date, undated or out-of-range calendars, completed days, blank email addresses, and readers not opted in. Individual failures are logged without stopping other deliveries; each run prints the delivered count.

## Avatar optimization

Profile and Admin uploads produce a **256×256 static WebP at quality 85**: auto-oriented, center-cropped, converted to sRGB, and stripped of thumbnail metadata. Transparency is preserved; animations use the first frame and small images are upscaled. Actual image data is validated, regardless of filename or declared type.

Limits are **2 MiB** by default (`config.avatar_max_bytes`) and **40 million pixels** in the selected frame/container canvas. The pixel limit bounds dimensions, not total processor memory. Processing or storage failure leaves the previous picture and profile details unchanged.

The current original, **including its metadata**, remains in `avatar`; the display image is stored as `avatar_thumbnail`. This retains a source for reprocessing, not a picture history, and increases storage even though downloads shrink. Removing or replacing a picture detaches the old pair; **keep Active Job workers running** for Active Storage purge jobs. No new migration is needed if Active Storage is already installed.

### Backfill existing uploads

Existing uploads display their originals until optimized. Run from the **host Rails app** with its normal database/storage credentials and the appropriate environment. Back up the database and storage before a production backfill.

```sh
# Metadata-only preview: no downloads or attachment changes
RAILS_ENV=production bundle exec rake bible270:avatars:optimize DRY_RUN=1

# Process sequentially in bounded batches
RAILS_ENV=production bundle exec rake bible270:avatars:optimize BATCH_SIZE=100

# Rebuild current thumbnails from retained originals
RAILS_ENV=production bundle exec rake bible270:avatars:optimize FORCE=1
```

- Skips current thumbnails, protects concurrent avatar changes, continues after individual failures, and exits nonzero if any fail. Correct failed files, limits, storage access, or processor dependencies, then rerun.
- Reports reader IDs, counts, and original/optimized **display-byte totals**, not total storage savings.
- `BATCH_SIZE` defaults to 100 (allowed: 1–1000). Dry-run checks eligibility only, not file availability or decodability.
- Reads originals and writes thumbnails to configured storage; remote storage may incur request/transfer costs. It does not fetch provider avatars or change unrelated host attachments.

Host upload code should use `reader.attach_avatar(upload)` or `Bible270::AvatarImages.update!(reader, attributes, upload: upload)`. Direct Active Storage attachment bypasses optimization. **Uploads and backfills must run outside caller-owned database transactions**: the service owns the commit boundary to prevent outer rollbacks from orphaning uploaded files. Failed cleanup retains unattached blob records and storage keys for retry; use logged blob IDs in your host's unattached-blob maintenance.

## Configuration reference

Common settings (example sender and host values must be replaced):

```ruby
Bible270.configure do |config|
  config.mount_at = "/daily-bread"
  config.app_name = "Daily Bread"
  config.tagline = "Journeying through Scripture in 9 months"
  config.admin_emails = %w[andrew@example.org]

  config.start_date = nil                  # no shared calendar by default
  config.allow_reader_start_date = true
  config.time_zone = nil                   # server clock, or a named zone
  config.daily_reminders = false           # schedule reminders:send separately
  config.mention_notifications = true      # readers choose notification scope
  config.mailer_host = "example.com"       # reminder/notice links

  config.parent_controller = "ActionController::Base" # or "::ApplicationController"
  config.layout = "bible270/application"

  config.email_sign_in = true
  config.mailer_from = "no-reply@example.com"
  config.email_sign_in_ttl = 20 * 60
  config.email_sign_in_ask_name = true
  config.email_sign_in_require_name = true
  config.omniauth_providers = [:github]
  config.omniauth_path_prefix = nil         # derive "<mount_at>/auth"
  config.current_reader_resolver = nil      # bridge host authentication
  config.require_sign_in_to_participate = true
  config.remember_for = 365 * 24 * 60 * 60   # seconds; nil/0 = session only

  config.after_sign_in_path = nil           # plan root
  config.after_sign_out_path = nil
  config.avatar_max_bytes = 2 * 1024 * 1024
  config.bible_version = "NKJV"
end
```

See [Authentication](#authentication), [Tuning the plan](#tuning-the-plan), and [`Configuration`](lib/bible270/configuration.rb) for additional options.

### Footer

Replace the engine's plan note with a host partial or HTML, or disable it:

```ruby
config.footer_partial = 'shared/footer' # app/views/shared/_footer.html.erb
# Alternatives:
config.footer_html = '<p>&copy; 2026 …</p>'
config.footer = false
```

To include both the engine note and your footer:

```ruby
config.footer_placement = :after   # engine, then yours
config.footer_placement = :before  # yours, then engine
config.footer_placement = :replace # default
```

Host partials can use host view paths, but engine controllers do not automatically include host helpers. If needed, add `helper ::ApplicationHelper` to the engine controller or keep the partial self-contained.

### Favicon

The engine layout uses an inline SVG loaf favicon, with no asset-pipeline setup:

```ruby
config.favicon = nil                  # built-in loaf (default)
config.favicon = '/icons/my-icon.svg'  # custom
config.favicon = false                # omit the engine's favicon
```

For a custom layout, add `<%= b270_favicon_tag %>` to `<head>`.

### Scripture links and popups

References link to **Bible.com** by default. Readers and admins can select **Bible Gateway** or **Blue Letter Bible** in reader preferences. Bible.com opens whole chapters. Scripture links reuse one browser tab; Ctrl/Cmd-click, middle-click, or the context menu can open additional tabs.

Original-language options exclude Bible Gateway:

| Option | Bible.com | Blue Letter Bible |
|---|---|---|
| `HEB/GRK` | WLC Old Testament; THGNT New Testament | WLC Old Testament; mGNT New Testament |
| `ALLGRK` | GRCBRENT Old Testament; THGNT New Testament | mGNT/LXX route for all tracks |

[Blue Letter Bible ScriptTagger](https://www.blueletterbible.org/webtools/BLB_ScriptTagger.cfm) adds Scripture-reference hover popups to reflections and replies, using the reader's translation or the site default. `HEB/GRK` and `ALLGRK` select languages by testament. The engine layout loads it automatically; custom layouts should render this once near the end of `<body>`:

```erb
<%= render "bible270/shared/scripture_popups" %>
```

ScriptTagger loads remote JavaScript and CSS. Add `https://www.blueletterbible.org` to existing CSP **`script-src`** and **`style-src`** directives. Page loads share the visitor's IP address and request metadata with BLB; hovering also sends the reference and selected translation.

## With ComfortableMediaSurfer

Mount the engine and add a CMS navigation link to use its own themed pages. To use your host's header and footer, set `config.parent_controller = "::ApplicationController"` and `config.layout = "layouts/application"`. Include the shared styles, theme attribute, and script partials described above when supplying a custom layout.

## Data model

| Table | Holds |
|-------|-------|
| `bible270_readers` | Identity, provider/uid or polymorphic owner, start date, and reader preferences |
| `bible270_checkoffs` | One row per reader/day/track/part, protected by a unique index |
| `bible270_comments` | Day/track reflections and replies, stored as plain text or safely rendered Markdown |
| `bible270_likes` | Reader likes on comments |
| `bible270_settings` | Shared run and administrative settings |
| `bible270_sign_in_tokens` | Email, token digest, expiry, and consumption time |

A day is complete when all parts of all three tracks are checked off. Progress and visible reflections are public; they are not private journals.

## Routes (inside the mount point)

Selected reader routes; see [`config/routes.rb`](config/routes.rb) for the full list, including Admin and Profile actions.

```text
GET    /                              days#index
GET    /day/:day                      days#show
POST   /day/:day/toggle/:track/:part   checkoffs#toggle
POST   /day/:day/toggle/:track         checkoffs#toggle (first part)
POST   /day/:day/comments              comments#create
GET    /reflections                   comments#index
POST   /comments/preview              comments#preview
PATCH  /comments/:id                  comments#update
DELETE /comments/:id                  comments#destroy
POST   /comments/:id/like             likes#toggle
GET    /community                     readers#index
GET    /mention-suggestions           readers#mention_suggestions (signed-in JSON)
GET    /readers/:id                    readers#show
GET    /progress                      readers#progress
GET    /sign_in                       sessions#new
POST   /sign_in/email                 sessions#email_link
GET    /sign_in/email/:token          sessions#email_callback
GET    /auth/:provider/callback       sessions#create
POST   /auth/:provider/callback       sessions#create
GET    /auth/failure                   sessions#failure
DELETE /sign_out                      sessions#destroy

POST   <mount>/auth/:provider         OmniAuth middleware, not the engine
```

## Tuning the plan

Prefer host configuration to editing the gem. Break points list the **last verse of each reading except the final one**; `[]` keeps a chapter whole:

```ruby
config.chapter_breaks = {
  'Luke 1' => [25, 56],        # 1–25, 26–56, 57–80
  'Psalm 78' => [20, 39, 55]   # 1–20, 21–39, 40–55, 56–72
}
config.chapter_breaks_path = Rails.root.join('config/bible270_breaks.yml')
```

```yaml
# config/bible270_breaks.yml — re-read when changed
Psalm 35: []
Psalm 78: [20, 39, 55]
```

Precedence is built-in `CHAPTER_BREAKS`, then `config.chapter_breaks`, then YAML. Ruby keys may also be arrays such as `['Luke', 1]`. Explicit breaks override default division rules, including Psalm 119's sections.

| `Bible270::Plan` constant | Default | Purpose |
|---|---|---|
| `DAYS` | `270` | Plan length |
| `PSALM_WHOLE_MAX_VERSES` | `25` | Keep shorter psalms whole unless explicitly overridden |
| `PSALM_119_SECTION_SIZE` | `16` | Default verses per Psalm 119 section |
| `CHAPTER_BREAKS` | Built-in chapter map | Selected breaks and whole-chapter overrides |

For New Testament and Psalms/Proverbs readings, explicit breaks fix a chapter's reading count; unpinned chapters divide by verse load to fill the remaining days. The Psalms/Proverbs track reserves the final day for Psalm 1. Without explicit breaks, divided chapters use equal parts.

Breaks must be ascending, distinct, and inside the chapter; invalid entries or too many pinned readings raise `ArgumentError`. Results are memoized and refreshed when configured breaks change. There is no stored schedule to migrate, but **changing assignments does not remap existing check-offs or reflections**. Test custom schedules before using them with an active group.

## Scaling

Community pages calculate completed days from grouped check-offs in Ruby. For large groups, profile this first; a cached `days_completed` counter on `Reader`, updated after check-off commits, is one possible optimization.

## Troubleshooting

**404 on the provider callback**

Match OmniAuth's `path_prefix` and the registered callback URL to the mount. Use `Bible270.config.auth_path_prefix` and check [initializer load order](#mount-point).

**Sign-in button does nothing, or `OmniAuth::AuthenticityError`**

Custom controls must POST with a CSRF token; use `button_to`. Confirm `omniauth-rails_csrf_protection` is bundled.

**No email arrives**

Check Action Mailer delivery settings, an accepted `mailer_from`, and logs. Sign-in uses `deliver_now` unless `email_sign_in_deliver_later` is enabled; for queued mail, check the Active Job worker too. Delivery failures are not shown to readers to avoid disclosing account information.

**“That link has expired or was already used”**

Request a fresh link. Links are single-use and expire after 20 minutes by default. Mail scanners or preview bots can consume them before the reader clicks; investigate prefetching if it recurs. Increase `email_sign_in_ttl` only if expiry is the problem—it cannot restore a consumed link.

**Custom layout is unstyled**

Add `<%= render "bible270/shared/styles" %>` to `<head>`, or style the `b270-*` classes yourself. Also include the theme attribute and shared scripts required by the features you use.

## Development

```bash
bundle install
bundle exec rake test
node --test test/javascript/*.cjs
bundle exec rubocop --cache false
```

`rake test` defaults to six isolated processes, prints combined results, writes coverage to `coverage/index.html`, and records runtimes in `tmp/parallel_runtime_test.log` for balancing. Set `PARALLEL_WORKERS` to change the count, or use `bundle exec rake test:serial` for serial coverage.

Video UI tests require **Node.js 22+**, use the built-in runner with no npm dependencies, and do not contact YouTube. Check live playback and host CSP separately in a browser. Plan logic is unit-tested without a Rails dependency.

### Get an email link for local testing

From the host app's console (`bin/rails console`):

```ruby
_record, raw = Bible270::SignInToken.issue!("John.Smith@example.com")
Bible270::Engine.routes.url_helpers.email_sign_in_url(token: raw, host: "localhost:3333")
```

Use your local host/port. If `raw` is nil, the address is invalid or rate-limited; no link was issued.

## Contributing

Report bugs or open pull requests at <https://github.com/avonderluft/bible270>.

Fork and clone the repository, branch from `main` (`git checkout -b my-feature`), and add tests with your change. Run the [development checks](#development), commit with a clear message, and open a pull request against `main` explaining what changed and why.

- Keep plan logic independent of Rails.
- Pin exact expected references in tests for schedule changes.
- Prefix new CSS classes and helpers with `b270`.
- Record user-visible changes in `CHANGELOG.md`.

## License

[MIT-LICENSE](./MIT-LICENSE).
