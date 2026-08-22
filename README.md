# Bible 270

[![Gem Version](https://img.shields.io/gem/v/bible270)](https://rubygems.org/gems/bible270) [![Coverage Status](https://coveralls.io/repos/github/avonderluft/bible270/badge.svg?branch=main&cache=20260812-1)](https://coveralls.io/github/avonderluft/bible270?branch=main) [![Downloads](https://img.shields.io/gem/dt/bible270)](https://rubygems.org/gems/bible270) [![GitHub Release Date - Published_At](https://img.shields.io/github/release-date/avonderluft/bible270?label=last%20release&color=seagreen)](https://github.com/avonderluft/bible270/releases)

A mountable **Rails engine** that drops a 270-day (9 month) interactive Bible reading plan into any Rails app, built with [ComfortableMediaSurfer](https://github.com/shakacode/comfortable-media-surfer) CMS in mind. Readers tick off each day's readings, post reflections, and see how everyone else is getting on, much like the social plans on Bible.com.

Initially created for use by students and faculty of [Kingdom Movement School of Ministry](https://www.kmsm.life/), to read through all of Scripture together during the school year. Thus it is potentially useful for any Bible School, Seminary, or Discipleship school working on a 9 month schedule.

## The plan

Three readings a day, sized by **verse count** so each day takes roughly the same time.

- **Old Testament** — once through, with Psalms and Proverbs in their own track. 
- **New Testament** — once through, a reading every day. 260 chapters over 270 days, long chapters are divided to even out the daily reading
- **Psalms & Proverbs** — once each, interleaved in one track. 181 chapters have to cover 270 days, so some are divided, shared between the two books by verse load. **A psalm of 25 verses or fewer is never divided**, keeping 131 of the 150 whole; longer psalms and Proverbs chapters break at their turns of thought (see `CHAPTER_BREAKS`). **Psalm 119 is 11 sections of 16 verses** — two of its eight-verse acrostic stanzas each. Proverbs lands on 89 days, near its proportional share. **A divided chapter is always read on consecutive days**, so nothing is inserted between the parts of a split psalm.

Genesis → Malachi and Revelation 22 both land on day 270, as does the second part of Proverbs 31.  Every day carries all three tracks. A typical day is ~119 verses (range 76–175).

The schedule is pure deterministic Ruby (`Bible270::Plan`) — none of it is stored. Portions come from per-chapter verse counts in `Bible270::Versification`. The DB only holds readers, check-offs, comments, and sign-in tokens.

## Requirements

- **Ruby** >= 3.2. Plain Ruby, no C extensions. Runs on 4.0.6 — it avoids everything 4.0 dropped or unbundled (notably `cgi`; URL escaping uses `URI.encode_www_form_component`).
- **Rails** >= 7.0. On Ruby 4.0 your host app is the real constraint, not this engine — check your lockfile with RailsBump first.
- A host app, and Turbo if you want check-offs without a page reload.

Mutation controls expose pending, success, and retry feedback when JavaScript runs, while ordinary HTML
forms remain the fallback. Repeated checkoff and like requests converge on the intended state rather
than accidentally reversing it.

## Install

```ruby
# Gemfile
gem "bible270"
```

<details>
<summary>Other sources</summary>

```ruby
gem "bible270", git: "https://github.com/avonderluft/bible270.git", branch: "main"
gem "bible270", path: "<path_to_your_local_copy>/bible270"   # local checkout
```
</details>

```bash
bundle install
bin/rails generate bible270:install
```

That's the whole install. The generator is interactive and walks you through it:

1. asks where to mount the plan;
2. asks which sign-in methods you want — email link, OmniAuth, or both — and adds any OmniAuth strategy gems to your `Gemfile`;
3. Prompts to install ActiveStorage for user avatars
4. copies migrations into your `db/migrate` and offers to run them;
5. writes `config/initializers/bible270.rb` (and `omniauth.rb` if you chose social sign-in); and
6. adds `mount Bible270::Engine, at: Bible270.config.mount_at` to `config/routes.rb`.

(Migrations run before the config is written, so a problem in a generated initializer can't block the database work.)

Every prompt has a default, so holding Enter gives a working install at `/daily-bread` with email and GitHub sign-in. It finishes by listing what's left for you — provider credentials, callback URLs, mailer setup.

The copied migrations are yours from then on, in your `schema.rb`. The engine doesn't add its own migration directory to your app's paths, so the copies are the only definitions in play.

Non-interactive (CI, re-runs, scripted setup):

```bash
bin/rails generate bible270:install --defaults \
  --mount-at=/daily-bread --providers=github,google_oauth2 \
  --mailer-from=no-reply@example.org --no-migrate
```

| Flag | Effect |
|------|--------|
| `--defaults` | Ask nothing, accept every default |
| `--mount-at=PATH` | Where to mount (default `/daily-bread`) |
| `--providers=a,b` | OmniAuth providers; `--providers=` for none |
| `--email` / `--no-email` | Email sign-in on or off |
| `--mailer-from=ADDR` | From: address for sign-in emails |
| `--bundle` / `--no-bundle` | Run `bundle install` after adding strategy gems |
| `--migrate` / `--no-migrate` | Run `db:migrate` at the end |
| `--active-storage` / `--no-active-storage` | Install Active Storage if missing (for picture uploads) |

The installer is safe to re-run: it leaves an existing `mount` line alone, skips strategy gems already in your Gemfile, and Rails prompts before overwriting an initializer.

<details>
<summary>Doing it by hand instead</summary>

```ruby
# config/initializers/bible270.rb
Bible270.configure do |config|
  config.mount_at   = "/daily-bread"
  config.email_sign_in = true
  config.mailer_from   = "no-reply@example.com"
  config.omniauth_providers = []            # or [:github], plus an OmniAuth initializer
end
```

```ruby
# config/routes.rb
mount Bible270::Engine, at: Bible270.config.mount_at
```

```bash
bin/rails bible270:install:migrations
bin/rails db:migrate
```

See [Authentication](#authentication) for the OmniAuth initializer.
</details>

### Upgrading

No need to re-run the generator — just pick up any new migrations:

```bash
bundle update bible270
bin/rails bible270:install:migrations   # skips ones you already have
bin/rails db:migrate
```

### Reconciling a copied database

A copied database can contain the Bible270 tables while its `schema_migrations` versions do not match
the timestamped migration copies in the local app. In that case, preview the reconciliation:

```bash
bin/rails bible270:migrations:reconcile
```

The task recognizes Bible270 migrations—and the related generated Active Storage migration used for
reader avatars—by name, then verifies their tables, columns, current indexes, and foreign keys. It
does not treat an existing table alone as sufficient. After reviewing the list and backing up the
database, record only the migrations already reflected in the schema:

```bash
APPLY=1 bin/rails bible270:migrations:reconcile
bin/rails db:migrate
```

Preview mode never writes to the database. Apply mode only inserts verified local versions into
`schema_migrations`; it does not create, remove, or alter application tables. Migrations whose changes
are missing remain pending for the final `db:migrate` command.

## Bible270 Mount point in your Rails app

The path lives in exactly **one** place, `config.mount_at`:

```ruby
# config/initializers/bible270.rb
Bible270.configure do |config|
  config.mount_at = "/daily-bread"    # or "/read270", "/manna", whatever you wish
end
```

Routes read it directly; OmniAuth reads `Bible270.config.auth_path_prefix` (just `"<mount_at>/auth"`). The engine builds its own sign-in links from `request.script_name` at runtime, so there's no third spot to update.

Values are normalised — `"read270"`, `"/read270"`, `"/read270/"` all become `/read270`. Nested paths and mounting at `/` work too.

Two things sit outside your app and still need doing by hand when you move it: the **OAuth callback URLs** in each provider's dashboard, and any **CMS links**.

> **Load order matters.** `bible270.rb` has to be read before `omniauth.rb`, since the latter asks for `auth_path_prefix`. Rails loads initializers alphabetically so the default names work fine. If you rename either, keep that order — or set `mount_at` in `config/application.rb`, which loads before all initializers.

Need OmniAuth somewhere unrelated? Set `config.omniauth_path_prefix` and it wins.

## Authentication

Two ways in, so **nobody's shut out**:

1. **Email link** — type an address, get a one-time link, click it. No password, no third-party account. The default, and what makes this usable by people with no GitHub or Google login.
2. **Social sign-in** via OmniAuth — for people who'd rather.

Either works alone: `omniauth_providers = []` for email-only, `email_sign_in = false` for social-only. Reading is always public; only ticking off and commenting need an account.

### Email links

```ruby
Bible270.configure do |config|
  config.email_sign_in = true
  config.mailer_from   = "no-reply@example.com"
  config.email_sign_in_ask_name = true
  config.email_sign_in_require_name = true   # first AND last name       # let readers pick their display name
  # config.email_sign_in_ttl = 20 * 60       # link lifetime, seconds
  # config.email_sign_in_max_per_window = 5  # per address
  # config.email_sign_in_window = 15 * 60
  # config.email_sign_in_deliver_later = true  # needs Active Job
end
```

All it needs is working Action Mailer delivery.

- Tokens: 256-bit, URL-safe, single-use, 20-minute expiry.
- **Only a SHA-256 digest is stored** — no password column anywhere, so the table is useless to anyone reading your DB.
- Claiming is a conditional update, so a double-clicked link still signs you in once.
- "Check your inbox" reads the same whether the address was known, unknown, or rate-limited — no account enumeration.
- Display name comes from the reader, else the address (`mary.anne.smith@…` → "Mary Anne Smith").
- `Bible270::SignInToken.sweep!` clears spent tokens. Good cron fodder.

Email readers get `provider: "email"` in the same columns OmniAuth uses, so everything downstream treats them identically.

### Social sign-in

`bin/rails generate bible270:install` sets this up: it adds the strategy gem to your `Gemfile`
(`omniauth` and `omniauth-rails_csrf_protection` already ride along with bible270), writes the
OmniAuth initializer, and prints the callback URL to register with each provider — for example
`https://example.com/daily-bread/auth/github/callback`.

Adding a provider later, or wiring it up yourself? Add its strategy gem, list it in `config.omniauth_providers`, and register it with OmniAuth. The one thing to get right is lining up `path_prefix` with the mount point:

```ruby
# config/initializers/omniauth.rb
Rails.application.config.middleware.use OmniAuth::Builder do
  # `options` is merged into every provider declared after it, so it comes first.
  # OmniAuth::Builder has no path_prefix method — this is the scoped equivalent.
  options path_prefix: Bible270.config.auth_path_prefix

  provider :github, ENV["GITHUB_CLIENT_ID"], ENV["GITHUB_CLIENT_SECRET"]
end

OmniAuth.config.on_failure = proc { |env| Bible270::SessionsController.action(:failure).call(env) }
```

```ruby
# config/initializers/bible270.rb
Bible270.configure do |config|
  config.mount_at           = "/daily-bread"
  config.omniauth_providers = [:github]      # or [:github, [:google_oauth2, "Google"]]
  config.parent_controller  = "::ApplicationController"
end
```

Worth knowing:

- **Sign-in is a POST.** OmniAuth 2.0+ refuses GET ([CVE-2015-9284](https://nvd.nist.gov/vuln/detail/CVE-2015-9284)), so the engine's controls are `button_to` forms with CSRF tokens. Build your own and it must POST to `<mount>/auth/:provider`.
- One provider → a button in the header. Several → a sign-in page at `<mount>/sign_in`.
- Sign-in carries the current path as `origin`, so clicking a check-off while signed out brings you back to that day. Origins must be local paths.
- `reset_session` on sign-in and sign-out, against session fixation.
- Stored: provider, uid, display name, email, avatar URL. No tokens, no passwords.

### Or use your own users

Already have auth? Hand the engine a resolver and it'll never touch sessions:

```ruby
config.current_reader_resolver = lambda do |controller|
  user = controller.send(:current_user)
  next nil unless user
  Bible270::Reader.for_owner(user, display_name: user.try(:name) || user.email,
                             email: user.try(:email), avatar_url: user.try(:avatar_url))
end
```

`Reader.for_owner` links to any host model polymorphically. Heads up: CMS admin auth is separate from public visitors, so for a public plan the email/OmniAuth route above is usually what you want.

## Admin panel

At `<mount>/admin`: remove readers, adjust their completions, move them to a given day. Unreachable —
every route 404s rather than 403s — unless you say who may use it:

```ruby
config.admin_emails = %w[andrew@example.org]
# or
config.admin_resolver = ->(reader) { reader.email.to_s.end_with?('@example.org') }
```

Admins get an extra "Admin" link in the header. From a reader's page you can:

- **move them to a day** — "put them on day 42 as of today" back-dates the start date; check-offs are
  keyed to day numbers, so nothing in their history moves;
- **set their progress** — mark complete through day N (this also clears anything after, so it sets
  progress exactly), or click days in the grid to toggle them;
- **remove them**, with every check-off and reflection they've written;
- **moderate reflections** at `<mount>/admin/comments`. Reflections are visible the moment they're
  written; hiding one takes it off the day and community pages without deleting it, and is
  reversible. Delete is there too, for anything that shouldn't be kept.

The Reflections page lists conversations by their latest approved reply, supports day and author
filters, and paginates older threads. Signed-in readers see which conversations became active since
their previous visit. Reflection and reply drafts are retained for up to 30 days in that browser and
cleared after a successful post. On a shared device, clearing browser storage also removes saved drafts.

After upgrading, copy and run migration `20260101000017`, which stores each reader's last visit to the
Reflections page:

```bash
bin/rails bible270:install:migrations
bin/rails db:migrate
```

Break points can also live in your app rather than the gem, and be changed without a restart:

```ruby
config.chapter_breaks = { 'Psalm 78' => [20, 39, 55] }
config.chapter_breaks_path = Rails.root.join('config/bible270_breaks.yml')
```

```yaml
# config/bible270_breaks.yml — re-read whenever it changes
Psalm 35: []
Psalm 78: [20, 39, 55]
```

## Start dates

The plan runs **undated** (day numbers only) or **dated** (days mapped onto a calendar):

```ruby
config.start_date = Date.new(2026, 9, 6)   # Date, Time, or "YYYY-MM-DD". nil = undated
config.allow_reader_start_date = true      # can readers set their own?
```

| `start_date` | `allow_reader_start_date` | What happens |
|---|---|---|
| nil | true *(default)* | Each reader gets stamped on first check-off, and can change it |
| a date | true | Community date is the default; anyone may override |
| a date | false | Everyone pinned to the community date, form hidden |
| nil | false | Fully undated — no calendar anywhere |

Dated plans show each day's date with a **Today** badge, a "Go to today" link, and whether you're ahead or behind. Readers set their own from the overview. Changing a start date only re-maps the calendar — check-offs and reflections are keyed to day numbers, so nothing moves.

Date helpers are pure functions, usable anywhere:

```ruby
Bible270::Plan.date_for(1, "2026-09-06")          # => Sun, 06 Sep 2026
Bible270::Plan.end_date_for("2026-09-06")         # => Wed, 02 Jun 2027 (day 270)
Bible270::Plan.day_for(Date.current, start)       # => 42 (clamped 1..270)
Bible270::Plan.day_for(date, start, clamp: false) # => -3 or 271, to spot out-of-range
Bible270::Plan.before_start?(date, start)
```

## Daily reading reminders

Daily reminders are optional at both levels: the host enables the feature, then each reader chooses
whether to receive it and at what local time from their profile. The feature and reader opt-in both
default to off; each reader's time defaults to `08:00`.

```ruby
# config/initializers/bible270.rb
Bible270.configure do |config|
  config.daily_reminders = true
  config.mailer_from = "no-reply@yourdomain.com"
  config.mailer_host = "yourdomain.com" # builds links back to the day and profile
end
```

After upgrading, copy and run migration `20260101000016`, which adds the reader opt-in, preferred
time, and last-sent date. Bible270 does not install a scheduler. The host application should run this
task periodically—every 15 minutes is recommended—using its existing cron, platform scheduler, or
recurring-job system:

```bash
bin/rails bible270:reminders:send
```

Each run converts `Time.now` through `Bible270.local_time`, waits until each reader's chosen `HH:MM`
time, sends inline with `deliver_now`, and prints the number delivered. Set `config.time_zone` when the
plan should not follow the server's local clock. Running periodically is safe because delivery is
idempotent once per local date: readers already marked for that date are skipped. Undated readers,
calendar dates before or after their plan, completed days, blank email addresses, and readers who have
not opted in are also skipped. A failure for one reader is logged and does not stop the rest. The sent
date is recorded only after delivery succeeds.

## Configuration reference

```ruby
Bible270.configure do |config|
  config.mount_at = "/daily-bread"         # single source of truth for the path
  config.app_name = "Daily Bread"
  config.tagline  = "A 270-day journey through Scripture"
  config.admin_emails = %w[andrew@example.org]

  config.start_date = nil       # community start date, or nil for undated
  # config.start_date = Date.new(2026, 9, 6)  
  config.allow_reader_start_date = true

  config.daily_reminders = false             # schedule reminders:send every 15 minutes
  config.mailer_host = "example.com"          # links in reminder/notice email

  config.parent_controller = "ActionController::Base"   # or "::ApplicationController"
  config.layout            = "bible270/application"

  config.email_sign_in = true
  config.mailer_from = "no-reply@example.com"
  config.email_sign_in_ttl = 20 * 60
  config.email_sign_in_ask_name = true
  config.omniauth_providers = [:github]
  config.omniauth_path_prefix = nil        # nil = derive "<mount_at>/auth"
  config.current_reader_resolver = nil     # set to bridge your own users
  config.require_sign_in_to_participate = true

  config.after_sign_in_path  = nil         # defaults to the plan root
  config.after_sign_out_path = nil

  config.bible_version = "NKJV"
  config.passage_url_builder = ->(reference, version) {
    "https://www.biblegateway.com/passage/?search=#{URI.encode_www_form_component(reference)}&version=#{version}"
  }
end
```
### Footer
 
The engine's pages end with a short note about how the plan works. Replace it with your own:
 
```ruby
config.footer_partial = 'shared/footer'      # a partial in your app
config.footer_html    = '<p>&copy; 2026 …</p>'
config.footer         = false                # no footer at all
```
 
By default yours replaces the engine's. To keep both:
 
```ruby
config.footer_placement = :after    # engine's note, then yours
config.footer_placement = :before   # yours, then the engine's note
config.footer_placement = :replace  # default
```
 
A partial is looked up in your app's view paths as well as the engine's, so `'shared/footer'` finds
`app/views/shared/_footer.html.erb`. Keep it reasonably self-contained: engine controllers include
the engine's helpers, not your app's, so a partial calling your own helpers needs
`helper ::ApplicationHelper` adding to the engine's controller — or just inline the markup.
 
### Favicon
 
Pages under the mount point carry their own favicon — a rustic loaf, inlined as an SVG data URI, so
there's nothing to add to your asset pipeline.
 
```ruby
config.favicon = nil                        # built-in loaf (default)
config.favicon = '/icons/my-icon.svg'       # your own
config.favicon = false                      # none; the host's favicon applies
```
 
It's emitted by the engine's layout, so if you point `config.layout` at your own layout, add
`<%= b270_favicon_tag %>` to its `<head>`.

References link to Bible Gateway by default. Readers choose Bible Gateway or Blue Letter Bible from
their profile, and an admin can set the same source for any reader. The `HEB/GRK` option always uses
Blue Letter Bible: WLC for Old Testament, Psalms, and Proverbs readings, and mGNT for New Testament
readings. Set `passage_url_builder` to use another default reader, or a reader you host yourself.

## With ComfortableMediaSurfer

The CMS serves your content; this is a separate mounted app. Either **just link to it** (mount, add a nav link, done — the engine renders its own themed pages), or **match your chrome** by setting `config.parent_controller = "::ApplicationController"` and `config.layout = "layouts/application"` so it sits inside your header and footer. All engine CSS is prefixed `b270-`, so nothing collides.

## Data model

| Table | Holds |
|-------|-------|
| `bible270_readers` | identity, avatar, provider/uid or polymorphic `owner`, start date, translation, passage-reader, and reminder preferences |
| `bible270_checkoffs` | one row per reader per day per track (`ot`/`nt`/`pp`), unique-indexed |
| `bible270_comments` | a reflection on a day, optionally scoped to a track, public to all |
| `bible270_sign_in_tokens` | magic-link tokens: email, **digest only**, expiry, consumed-at |

A day is "complete" once all three tracks are ticked. Progress and comments are **public** by
design, same as Bible.com's shared plans.

## Routes (inside the mount point)

```
GET    /                         days#index      overview + community + calendar
GET    /day/:day                 days#show       readings, who's finished, reflections
POST   /day/:day/toggle/:track   checkoffs#toggle
POST   /day/:day/comments        comments#create
DELETE /comments/:id             comments#destroy
PATCH  /start-date               readers#update_start_date
DELETE /start-date               readers#clear_start_date
GET    /community                readers#index   leaderboard
GET    /readers/:id              readers#show
GET    /sign_in                  sessions#new    email form + provider list
POST   /sign_in/email            sessions#email_link
GET    /sign_in/email/:token     sessions#email_callback
GET    /auth/:provider/callback  sessions#create
POST   /auth/:provider/callback  sessions#create
GET    /auth/failure             sessions#failure
DELETE /sign_out                 sessions#destroy

POST   <mount>/auth/:provider    OmniAuth middleware, not the engine
```

## Tuning the plan

The whole schedule falls out of a few constants in `Bible270::Plan`:

| Constant | Default | Effect |
|----------|---------|--------|
| `DAYS` | `270` | plan length |
| `PROVERBS_PASSES` | `2` | Proverbs laps. Each pass is 31 readings, so this decides how many days are left for the Psalms |
| `PSALM_119_SECTION_SIZE` | `16` | verses per Psalm 119 section. 176 divides evenly by 8, 11, 16, 22 and 44 |
| `CHAPTER_BREAKS` | `{}` | where specific chapters break — see below |

### Choosing where a chapter breaks

By default a divided chapter is cut into equal parts. To break it somewhere meaningful instead, add
an entry to `CHAPTER_BREAKS` in `lib/bible270/plan.rb`. Keys are `[book, chapter]`; the value lists
the **last verse of every reading except the final one**:

```ruby
CHAPTER_BREAKS = {
  ['Luke', 1]   => [25, 56],   # => Luke 1:1–25, 1:26–56, 1:57–80
  ['Psalm', 78] => [39]        # => Psalm 78:1–39, 78:40–72
}.freeze
```

The number of breaks fixes how many readings that chapter becomes, and the rest of the plan
re-divides around it so both tracks still fill exactly 270 days — give Luke 1 a third reading and
some other long chapter quietly gives one up. Verse coverage stays exact either way.

Break points are validated on use: they must be ascending, distinct, and within the chapter, or you
get an `ArgumentError` naming the entry rather than silently overlapping readings. Pinning more
readings in total than there are days also raises, instead of producing a plan that doesn't fit.

Psalm 119 is pinned to `PSALM_119_SECTION_SIZE` sections by default; an entry in `CHAPTER_BREAKS`
overrides that.

Change `PROVERBS_PASSES` or `DAYS` and both the New Testament and the Psalms re-divide automatically
to fill whatever's left. Divisions always go to whichever chapter currently carries the heaviest
reading, so the longest get split first and nothing is divided that doesn't need to be.

All computed at load and memoized — no generated schedule, so nothing to migrate if you change them.

## Scaling

Community pages count completed days in Ruby from grouped check-offs — fine for hundreds of readers. Past a few thousand, cache a `days_completed` counter on `Reader` via a `Checkoff` `after_commit` and read it directly in SQL.

## Troubleshooting

**404 on the provider callback**

`path_prefix` doesn't match the mount point. Use `Bible270.config.auth_path_prefix` rather than a literal, and check the URL registered with the provider matches. Setting `mount_at` in an initializer Rails loads *after* `omniauth.rb` gives you the default prefix — see [Mount point](#bible270-mount-point-in-your-rails-app).

**Sign-in button does nothing, or `OmniAuth::AuthenticityError`**

Has to be a POST with a CSRF token. The engine's controls already are — if you built your own, make it a `button_to`. Also check `omniauth-rails_csrf_protection` is in the bundle.

**No email arrives**

Needs working Action Mailer delivery — the engine just calls `deliver_now`. Check `mailer_from` is an address your relay accepts, and watch the logs. Failures never surface to the reader, on purpose, since that message can't reveal which addresses exist.

**"That link has expired or was already used"**

Links are single-use, 20-minute life. Some mail scanners and link-preview bots fetch URLs before the recipient clicks, burning the token. If it keeps happening, lengthen `email_sign_in_ttl` or find what's prefetching.

**Everything's unstyled in my layout**

The engine's CSS rides in a partial its own layout renders. Using your layout? Add `<%= render "bible270/shared/styles" %>` to the `<head>`, or style the `b270-*` classes yourself.

## Development

```bash
bundle install
bundle exec rake test
bundle exec rubocop --cache false
```

`rake test` runs two isolated processes, streams colorized progress in real time, then prints one
consolidated result and duration. It merges their SimpleCov results, writes a browsable report to
`coverage/index.html`, and
records per-file runtimes in `tmp/parallel_runtime_test.log` to improve
subsequent balancing. Set `PARALLEL_WORKERS` to tune the worker count. Use
`bundle exec rake test:serial` when a serial coverage run is specifically needed; it writes to the same
project-local `coverage/` directory.

### Get an email link for local testing

in the rails console: `rails c`
```
_record, raw = Bible270::SignInToken.issue!("John.Smith@example.com")
Bible270::Engine.routes.url_helpers.email_sign_in_url(token: raw, host: "localhost:3333")
```

Plan logic is fully unit-tested with no Rails dependency.

## Contributing

Bug reports and pull requests are welcome at <https://github.com/avonderluft/bible270>.

1. Fork it and clone your fork.
2. Branch off `main`: `git checkout -b my-feature`.
3. Make your change, and add tests — `bundle exec rake test` and `bundle exec rubocop --cache false` should stay green.
4. Commit with a clear message: `git commit -am "Add my feature"`.
5. Push: `git push origin my-feature`.
6. Open a pull request against `main`, saying what changed and why.

A few things that'll make review quick:

- Keep plan logic free of Rails so it stays unit-testable.
- Anything touching the reading schedule needs a test pinning the expected references — the plan is deterministic, so assert exact values.
- Prefix new CSS classes and helpers with `b270`.
- Note anything user-visible in `CHANGELOG.md`.

## License

[MIT-LICENSE](./MIT-LICENSE).
