# Bible 270

[![Gem Version](https://badge.fury.io/rb/bible270.svg)](https://badge.fury.io/rb/bible270) [![Gem Downloads](https://img.shields.io/gem/dt/bible270.svg?style=flat)](http://rubygems.org/gems/bible270) [![GitHub Release Date - Published_At](https://img.shields.io/github/release-date/avonderluft/bible270?label=last%20release&color=seagreen)](https://github.com/avonderluft/bible270/releases)

A mountable **Rails engine** that drops a 270-day (9 month) interactive Bible reading plan into any Rails app, built with [ComfortableMediaSurfer](https://github.com/shakacode/comfortable-media-surfer) CMS in mind. Readers tick off each day's readings, post reflections, and see how everyone else is getting on, much like the social plans on Bible.com.

Initially created for use by students and faculty of [Kingdom Movement School of Ministry](https://www.kmsm.life/), to read through all of Scripture together, during the school year. Thus it is potentially useful for any Bible School, Seminary, or Discipleship school with a 9 month school year.

## The plan

Three readings a day, sized by **verse count** so each day takes roughly the same time.

- **Old Testament** — once through, with Psalms and Proverbs live in their own track. Whole chapters grouped so each day is ~73 verses (range 38–116).
- **New Testament** — once through, a reading every day. 260 chapters over 270 days, so the 10 longest are halved (Luke 1, Matthew 26–27, Mark 14, Luke 9, 12, 22, John 6,8, Acts 7).
- **Psalms & Proverbs** — Psalms once, Proverbs twice, interleaved in one track. Proverbs supplies 62 whole-chapter readings, leaving 208 days for the Psalms; longer psalms are divided to fill them. **Psalm 119 is pinned to 11 sections of exactly 16 verses** (176 = 11 × 16, i.e. two of its eight-verse acrostic stanzas per reading), and 41 psalms in total get divided so no single reading tops 20 verses.

Genesi → Malachi and Revelation 22 both land on day 270, as does the second Proverbs 31 — the first falls on day 135, the midpoint. Psalm 150 comes in on day 269. Every day carries all three tracks. A typical day is ~119 verses (range 76–175).

The schedule is pure deterministic Ruby (`Bible270::Plan`) — none of it is stored. Portions come from per-chapter verse counts in `Bible270::Versification`. The DB only holds readers, check-offs, comments, and sign-in tokens.

## Requirements

- **Ruby** >= 3.0. Plain Ruby, no C extensions. Runs on 4.0.6 — it avoids everything 4.0 dropped or unbundled (notably `cgi`; URL escaping uses `URI.encode_www_form_component`).
- **Rails** >= 7.0. On Ruby 4.0 your host app is the real constraint, not this engine — check your lockfile with RailsBump first.
- A host app, and Turbo if you want check-offs without a page reload.

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
bin/rails bible270:install:migrations
bin/rails db:migrate
```

That copies four migrations into your `db/migrate` — yours from then on, in your `schema.rb`. The engine doesn't touch your migration paths, so the copies are the only definitions in play.

Mount it:

```ruby
# config/routes.rb
mount Bible270::Engine, at: Bible270.config.mount_at
```

Optionally generate the initializers:

```bash
bin/rails generate bible270:install --providers=github
```

You're live at `/daily-bread`.

### Upgrading

```bash
bundle update bible270
bin/rails bible270:install:migrations   # skips ones you already have
bin/rails db:migrate
```

## Bible270 Mount point in your Rails app

The path lives in exactly **one** place, `config.mount_at`:

```ruby
# config/initializers/bible270.rb
Bible270.configure do |config|
  config.mount_at = "/daily-bread"    # or "/read270", "/manna", whatever you wish
end
```

Routes read it directly; OmniAuth reads `Bible270.config.auth_path_prefix` (just
`"<mount_at>/auth"`). The engine builds its own sign-in links from `request.script_name` at runtime, so there's no third spot to update.

Values are normalised — `"read270"`, `"/read270"`, `"/read270/"` all become `/read270`. Nested paths and mounting at `/` work too.

Two things sit outside your app and still need doing by hand when you move it: the **OAuth callback URLs** in each provider's dashboard, and any **CMS links**.

> **Load order matters.** `bible270.rb` has to be read before `omniauth.rb`, since the latter asks for `auth_path_prefix`. Rails loads initializers alphabetically so the default names work fine. If you rename either, keep that order — or set `mount_at` in `config/application.rb`, which loads before all initializers.

Need OmniAuth somewhere unrelated? Set `config.omniauth_path_prefix` and it wins.

## Authentication

Two ways in, so **nobody's shut out**:

1. **Email link** — type an address, get a one-time link, click it. No password, no third-party account. The default, and what makes this usable by people with no GitHub or Google login.
2. **Social sign-in** via OmniAuth — for people who'd rather.

Either works alone: `omniauth_providers = []` for email-only, `email_sign_in = false` for
social-only. Reading is always public; only ticking off and commenting need an account.

### Email links

```ruby
Bible270.configure do |config|
  config.email_sign_in = true
  config.mailer_from   = "no-reply@example.com"
  config.email_sign_in_ask_name = true       # let readers pick their display name
  # config.email_sign_in_ttl = 20 * 60       # link lifetime, seconds
  # config.email_sign_in_max_per_window = 5  # per address
  # config.email_sign_in_window = 15 * 60
  # config.email_sign_in_deliver_later = true  # needs Active Job
end
```

All it needs is working Action Mailer delivery.

- Tokens: 256-bit, URL-safe, single-use, 20-minute expiry.
- **Only a SHA-256 digest is stored** — no password column anywhere, so the table is useless to
  anyone reading your DB.
- Claiming is a conditional update, so a double-clicked link still signs you in once.
- "Check your inbox" reads the same whether the address was known, unknown, or rate-limited — no
  account enumeration.
- Display name comes from the reader, else the address (`mary.anne.smith@…` → "Mary Anne Smith").
- `Bible270::SignInToken.sweep!` clears spent tokens. Good cron fodder.

Email readers get `provider: "email"` in the same columns OmniAuth uses, so everything downstream
treats them identically.

### Social sign-in

The generator writes both initializers for you and adds the `mount` line:

```bash
bin/rails generate bible270:install --providers=github
```

Add the strategy gem (`omniauth` and `omniauth-rails_csrf_protection` ride along with bible270):

```ruby
gem "omniauth-github"
```

Register the callback with the provider — `https://example.com/daily-bread/auth/github/callback`.

Doing it by hand? The one thing to get right is lining up `path_prefix` with the mount point:

```ruby
# config/initializers/omniauth.rb
Rails.application.config.middleware.use OmniAuth::Builder do
  path_prefix Bible270.config.auth_path_prefix
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

- **Sign-in is a POST.** OmniAuth 2.0+ refuses GET
  ([CVE-2015-9284](https://nvd.nist.gov/vuln/detail/CVE-2015-9284)), so the engine's controls are
  `button_to` forms with CSRF tokens. Build your own and it must POST to `<mount>/auth/:provider`.
- One provider → a button in the header. Several → a sign-in page at `<mount>/sign_in`.
- Sign-in carries the current path as `origin`, so clicking a check-off while signed out brings you
  back to that day. Origins must be local paths.
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

`Reader.for_owner` links to any host model polymorphically. Heads up: CMS admin auth is separate
from public visitors, so for a public plan the email/OmniAuth route above is usually what you want.

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

Dated plans show each day's date with a **Today** badge, a "Go to today" link, and whether you're
ahead or behind. Readers set their own from the overview. Changing a start date only re-maps the
calendar — check-offs and reflections are keyed to day numbers, so nothing moves.

Date helpers are pure functions, usable anywhere:

```ruby
Bible270::Plan.date_for(1, "2026-09-06")          # => Sun, 06 Sep 2026
Bible270::Plan.end_date_for("2026-09-06")         # => Wed, 02 Jun 2027 (day 270)
Bible270::Plan.day_for(Date.current, start)       # => 42 (clamped 1..270)
Bible270::Plan.day_for(date, start, clamp: false) # => -3 or 271, to spot out-of-range
Bible270::Plan.before_start?(date, start)
```

## Configuration reference

```ruby
Bible270.configure do |config|
  config.mount_at = "/daily-bread"         # single source of truth for the path
  config.app_name = "Daily Bread"
  config.tagline  = "A 270-day journey through Scripture"

  config.start_date = nil                  # community start date, or nil for undated
  config.allow_reader_start_date = true

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

References link to Bible Gateway by default — point `passage_url_builder` at your another reader if you wish, or your own reader if you host one.

## With ComfortableMediaSurfer

The CMS serves your content; this is a separate mounted app. Either **just link to it** (mount, add a nav link, done — the engine renders its own themed pages), or **match your chrome** by setting `config.parent_controller = "::ApplicationController"` and `config.layout = "layouts/application"`
so it sits inside your header and footer. All engine CSS is prefixed `b270-`, so nothing collides.

## Data model

| Table | Holds |
|-------|-------|
| `bible270_readers` | identity: display name, avatar, provider/uid or polymorphic `owner`, `started_on` |
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

Change `PROVERBS_PASSES` or `DAYS` and both the New Testament and the Psalms re-divide automatically
to fill whatever's left. Divisions always go to whichever chapter currently carries the heaviest
reading, so the longest get split first and nothing is divided that doesn't need to be.

All computed at load and memoized — no generated schedule, so nothing to migrate if you change them.

## Scaling

The leaderboard counts completed days in Ruby from grouped check-offs — fine for hundreds of
readers. Past a few thousand, cache a `days_completed` counter on `Reader` via a `Checkoff`
`after_commit` and sort in SQL.

## Troubleshooting

**`DuplicateMigrationNameError: Multiple migrations have the name CreateBible270Readers`**

0.6.2 and earlier wrongly added the engine's `db/migrate` to your app's paths *and* shipped
`install:migrations`, so copying defined everything twice. `bundle update bible270` to >= 0.6.3,
keep your copies, migrate.

**404 on the provider callback**

`path_prefix` doesn't match the mount point. Use `Bible270.config.auth_path_prefix` rather than a
literal, and check the URL registered with the provider matches. Setting `mount_at` in an initializer
Rails loads *after* `omniauth.rb` gives you the default prefix — see [Mount point](#mount-point).

**Sign-in button does nothing, or `OmniAuth::AuthenticityError`**

Has to be a POST with a CSRF token. The engine's controls already are — if you built your own, make
it a `button_to`. Also check `omniauth-rails_csrf_protection` is in the bundle.

**No email arrives**

Needs working Action Mailer delivery — the engine just calls `deliver_now`. Check `mailer_from` is
an address your relay accepts, and watch the logs. Failures never surface to the reader, on purpose,
since that message can't reveal which addresses exist.

**"That link has expired or was already used"**

Links are single-use, 20-minute life. Some mail scanners and link-preview bots fetch URLs before the
recipient clicks, burning the token. If it keeps happening, lengthen `email_sign_in_ttl` or find
what's prefetching.

**Everything's unstyled in my layout**

The engine's CSS rides in a partial its own layout renders. Using your layout? Add
`<%= render "bible270/shared/styles" %>` to the `<head>`, or style the `b270-*` classes yourself.

## Development

```bash
bundle install
rake test
```

Plan logic is fully unit-tested with no Rails dependency.

## Contributing

Bug reports and pull requests are welcome at <https://github.com/avonderluft/bible270>.

1. Fork it and clone your fork.
2. Branch off `main`: `git checkout -b my-feature`.
3. Make your change, and add tests — `rake test` should stay green.
4. Commit with a clear message: `git commit -am "Add my feature"`.
5. Push: `git push origin my-feature`.
6. Open a pull request against `main`, saying what changed and why.

A few things that'll make review quick:

- Keep plan logic free of Rails so it stays unit-testable.
- Anything touching the reading schedule needs a test pinning the expected references — the plan is
  deterministic, so assert exact values.
- Prefix new CSS classes and helpers with `b270`.
- Note anything user-visible in `CHANGELOG.md`.

## License

MIT. See `MIT-LICENSE`.
