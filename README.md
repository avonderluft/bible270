# bible270

A mountable **Rails engine** that adds a social, 270-day Bible reading plan to a
host Rails application such as [ComfortableMediaSurfer](https://github.com/shakacode/comfortable-mexican-sofa).

Each day presents three readings, sized by **verse count** so daily portions take roughly
the same time to read. Chapters are kept **whole** — the plan never chops a chapter into
verse ranges except for the one excessively long chapter, Psalm 119.

- **Old Testament** — read once, cover to cover. Whole chapters grouped so each day is
  ~equal in verses (avg ~73/day, range 38–116).
- **New Testament** — read **twice**. Each pass gets half the plan (135 days), so
  Revelation lands on day 135 and again on day 270. ~2 chapters/day, every day, verse-balanced
  within each pass.
- **Psalms & Proverbs** — a whole-chapter companion that runs **twice** over the 270 days
  (135 portions x 2). Very short chapters merge with a neighbour so there are no trivial
  two-verse days (Psalm 117 reads as "Psalm 116–117"), and **Psalm 119 (176 verses) is the
  sole chapter divided** — into exactly two readings, 1–88 and 89–176.

Genesis→Malachi, the second pass through Revelation, and Proverbs 31 all finish together on
day 270. A typical day runs ~157 verses across the three tracks (range 102–238).

Readers check off each track, leave reflections (comments) on any day, and can see everyone
else's progress and reflections — similar to the social plans on Bible.com.

The plan itself is pure, deterministic Ruby (`Bible270::Plan`) — no rows are stored for the
schedule. Daily portions are sized using per-chapter verse counts (`Bible270::Versification`,
standard English/KJV versification; verse counts are facts about the text's structure, so
nothing copyrighted is bundled). The database only holds **readers, check-offs, and comments**.

## Requirements & compatibility

- **Ruby** >= 3.0 (the gemspec's `required_ruby_version`). The plan logic is plain Ruby with
  no C extensions and no dependency on any gem that Ruby 4.0 unbundled.
- **Ruby 4.0 notes.** Audited against the 4.0 breaking changes: the gem does not use `cgi`
  (removed from default gems in 4.0 — URL escaping goes through `URI.encode_www_form_component`
  instead, which is byte-identical to `CGI.escape`), `Set`/`SortedSet`, `Ractor`, `Net::HTTP`,
  `Process::Status`, `ObjectSpace`, or any of the gems promoted from default to bundled
  (`ostruct`, `logger`, `benchmark`, `pstore`, `irb`, `rdoc`). Every file carries a
  `# frozen_string_literal: true` magic comment and no string literal is mutated.
- **Rails.** The gemspec allows `rails >= 7.0`, but on Ruby 4.0 the binding constraint is your
  host app, not this engine: Rails 8.0/8.1 require Ruby >= 3.2, and ComfortableMediaSurfer is a
  "Rails 7.0+" engine. Verify your own lockfile (e.g. with RailsBump) before pairing an older
  Rails with Ruby 4.0.
- A host application (this is an engine, not a standalone app).
- Turbo is used for seamless check-offs and degrades to full-page redirects if absent.

## Install

Add to the host app's `Gemfile`:

```ruby
gem "bible270", path: "vendor/gems/bible270"
# or, once pushed to a git remote:
# gem "bible270", git: "https://github.com/avonderluft/bible270.git", branch: "main"
```

Then:

```bash
bundle install
bin/rails bible270:install:migrations
bin/rails db:migrate
```

Mount it in `config/routes.rb`:

```ruby
mount Bible270::Engine, at: "/reading-plan"
```

The plan is now live at `/reading-plan`.

---

## Authentication

Two built-in ways to sign in, so **nobody is excluded**:

1. **Email link (passwordless)** — the reader types their address, gets a one-time link, and
   clicks it. No password, no account with anyone else. This is the default and it's what makes
   the plan usable by people who don't have (or don't want to use) GitHub, Google, and friends.
2. **OmniAuth social sign-in** — optional convenience for those who do.

Either can run alone. `config.omniauth_providers = []` gives you an email-only site;
`config.email_sign_in = false` gives you social-only. Viewing the plan and reading others'
reflections stays public either way — only checking off and commenting require signing in.

### Email sign-in

```ruby
Bible270.configure do |config|
  config.email_sign_in = true
  config.mailer_from   = "no-reply@gknt.org"
  config.email_sign_in_ask_name = true       # reader picks their display name
  # config.email_sign_in_ttl = 20 * 60       # link lifetime (seconds)
  # config.email_sign_in_max_per_window = 5  # per address, per window
  # config.email_sign_in_window = 15 * 60
  # config.email_sign_in_deliver_later = true  # needs an Active Job backend
end
```

The host app needs working Action Mailer delivery — nothing else. How it behaves:

- Tokens are 256-bit, URL-safe, single-use, and expire (20 minutes by default).
- **Only a SHA-256 digest of the token is stored**, so the table is useless to anyone who reads
  the database. There is no password column anywhere in this gem.
- Consuming a link is a conditional update, so a double-clicked link can't sign in twice.
- The "check your inbox" response is identical whether the address was known, unknown, or
  rate-limited — no account enumeration and no hint that a limit was hit.
- Readers may set the display name shown beside their reflections; otherwise it's derived from the
  address (`mary.anne.smith@…` → "Mary Anne Smith").
- Spent and stale tokens can be cleaned up with `Bible270::SignInToken.sweep!` from a cron/rake task.

An email reader gets `provider: "email"` in the same identity columns OmniAuth uses, so downstream
(progress, comments, leaderboard) treats every reader identically.

### OmniAuth social sign-in

### Quick setup

```bash
bin/rails generate bible270:install --mount-at=/reading-plan --providers=github
```

That writes `config/initializers/bible270.rb` (email sign-in enabled) and
`config/initializers/omniauth.rb` (with `path_prefix` already matching your mount point), and adds
the `mount` line to your routes. Pass `--providers=` with an empty value for an email-only site.
Then add the gems you need and migrate:

```ruby
# Gemfile — omniauth and omniauth-rails_csrf_protection come in with bible270;
# the provider strategy is your choice:
gem "omniauth-github"
```

```bash
bundle install
bin/rails bible270:install:migrations && bin/rails db:migrate
```

Finally register the callback URL with the provider:

```
https://gknt.org/reading-plan/auth/github/callback
```

### Manual setup

If you'd rather not use the generator, the only subtlety is that OmniAuth's `path_prefix` must
line up with where the engine is mounted, so its callback lands on the engine's route:

```ruby
# config/initializers/omniauth.rb
Rails.application.config.middleware.use OmniAuth::Builder do
  path_prefix "/reading-plan/auth"          # == <mount point>/auth
  provider :github, ENV["GITHUB_CLIENT_ID"], ENV["GITHUB_CLIENT_SECRET"]
end

OmniAuth.config.on_failure = proc { |env| Bible270::SessionsController.action(:failure).call(env) }
```

```ruby
# config/initializers/bible270.rb
Bible270.configure do |config|
  config.omniauth_providers = [:github]              # or [:github, [:google_oauth2, "Google"]]
  config.parent_controller  = "::ApplicationController"
end
```

### Notes worth knowing

- **Sign-in is a POST, not a link.** OmniAuth 2.0+ refuses GET on its request phase
  (CVE-2015-9284), so every sign-in control the engine renders is a `button_to` carrying a CSRF
  token, and `omniauth-rails_csrf_protection` provides the Rails-aware verifier. If you build your
  own sign-in link, it must POST to `<mount>/auth/:provider`.
- **One provider vs several.** With a single configured provider the header shows a direct
  "Sign in with X" button; with several it links to a sign-in page (`GET <mount>/sign_in`) listing
  them all.
- **Return-to-origin.** Sign-in controls pass the current path as `origin`, so a reader who clicks
  a check-off while signed out lands back on that same day afterwards. Origins are validated to be
  local paths only.
- **Session hygiene.** `reset_session` runs on both sign-in and sign-out to avoid session fixation.
  Sign-out is `DELETE <mount>/sign_out`.
- **What's stored.** Provider, uid, display name, email, and avatar URL — no tokens, no passwords.

### Alternative: bridge your host's own users

If the host app already has authentication and you'd rather not use OmniAuth at all, set a
resolver instead and the engine will never touch sessions:

```ruby
config.current_reader_resolver = lambda do |controller|
  user = controller.send(:current_user)
  next nil unless user
  Bible270::Reader.for_owner(user, display_name: user.try(:name) || user.email,
                             email: user.try(:email), avatar_url: user.try(:avatar_url))
end
```

`Reader.for_owner` links a reader to any host model polymorphically via `owner`. Note that
ComfortableMediaSurfer's admin authentication is separate from public site visitors, so for a
public plan on a CMS front-end the OmniAuth path above is usually the right fit.

## Start dates

The plan works either **undated** (day numbers only) or **dated** (day numbers mapped onto a
calendar). There are two levers:

```ruby
Bible270.configure do |config|
  # A community-wide start date — everyone reads together as a cohort.
  # Accepts a Date, Time, or "YYYY-MM-DD" string. Default: nil (undated).
  config.start_date = Date.new(2026, 9, 6)

  # May an individual reader set/change their own start date? Default: true.
  # Set false to pin everyone to config.start_date.
  config.allow_reader_start_date = true
end
```

How the two combine:

| `start_date` | `allow_reader_start_date` | Behaviour |
|---|---|---|
| nil | true (default) | Each reader is stamped with their own start date the first time they check something off, and can change it. |
| a date | true | The community date is the default; any reader may override it with their own. |
| a date | false | Everyone is pinned to the community date. The per-reader form is hidden. |
| nil | false | Fully undated — day numbers only, no calendar anywhere. |

When a plan is dated, each day page shows its calendar date with a **Today** badge, the overview
gains a "Go to today" link, and readers see whether they're ahead of or behind the pace.

Readers manage their own date from the overview page (`PATCH /start-date`, `DELETE /start-date`).
Changing a start date only re-maps days onto the calendar — check-offs and reflections are keyed
to day numbers and are never touched.

The date helpers are pure functions on `Bible270::Plan`, so you can use them anywhere:

```ruby
Bible270::Plan.date_for(1, "2026-09-06")        # => Sun, 06 Sep 2026
Bible270::Plan.end_date_for("2026-09-06")       # => Wed, 02 Jun 2027  (day 270)
Bible270::Plan.day_for(Date.current, start)     # => 42   (clamped to 1..270)
Bible270::Plan.day_for(date, start, clamp: false) # => -3 or 271, to detect out-of-range
Bible270::Plan.before_start?(date, start)       # => true/false
```

## Configuration reference

```ruby
Bible270.configure do |config|
  config.app_name = "Daily Bread"
  config.tagline  = "A 270-day journey through Scripture"

  config.start_date = nil                  # community start date, or nil for undated
  config.allow_reader_start_date = true    # may readers set their own?

  config.parent_controller = "ActionController::Base"      # or "::ApplicationController"
  config.layout            = "bible270/application"

  config.email_sign_in = true                              # passwordless email link
  config.mailer_from = "no-reply@example.com"
  config.email_sign_in_ttl = 20 * 60
  config.email_sign_in_ask_name = true
  config.omniauth_providers = [:github]                    # optional social sign-in
  config.omniauth_path_prefix = nil                        # nil = derive "<mount>/auth"
  config.current_reader_resolver = nil                     # set to bridge host users instead
  config.require_sign_in_to_participate = true

  config.after_sign_in_path  = nil                         # defaults to plan root
  config.after_sign_out_path = nil

  config.bible_version = "ESV"
  config.passage_url_builder = ->(reference, version) {
    "https://www.biblegateway.com/passage/?search=#{URI.encode_www_form_component(reference)}&version=#{version}"
  }
end
```

Every reading reference links out to the configured Bible reader (Bible Gateway by
default). Point `passage_url_builder` at your own reader if you host one.

---

## Using it inside ComfortableMediaSurfer

ComfortableMediaSurfer serves marketing/content pages; this engine is a separate
mounted app. Two integration styles:

1. **Link to it** — mount at `/reading-plan` and add a CMS navigation link. The
   engine renders its own themed pages. Simplest and fully featured.

2. **Match the site chrome** — set `config.parent_controller = "::ApplicationController"`
   and `config.layout = "layouts/application"` (your site layout) so the plan pages
   sit inside your normal header/footer. The engine's scoped CSS (all classes are
   prefixed `b270-`) won't collide with CMS styles.

Because CMS admin auth (`ComfortableMediaSurfer`) is separate from public readers,
Option B (OmniAuth) is usually the right fit for public visitors on gknt.org.

---

## Data model

| Table | Purpose |
|-------|---------|
| `bible270_readers` | identity: display name, avatar, provider/uid or polymorphic `owner`, `started_on` |
| `bible270_checkoffs` | one row per reader per day per track (`ot`/`nt`/`pp`); unique index prevents dups |
| `bible270_sign_in_tokens` | short-lived magic-link tokens: email, **digest only**, expiry, consumed-at |
| `bible270_comments` | a reflection on a day (optionally scoped to a track), public to all |

A day counts as "complete" for a reader when they've checked every track that has
content that day (2 on a light-NT day, otherwise 3). All progress and comments are
**public** to other readers by design (mirroring Bible.com's shared plans).

## Routes (within the mount point)

```
GET    /                         days#index      overview + community + calendar
GET    /day/:day                 days#show       three readings, completers, reflections
POST   /day/:day/toggle/:track   checkoffs#toggle
POST   /day/:day/comments        comments#create
DELETE /comments/:id             comments#destroy
PATCH  /start-date               readers#update_start_date
DELETE /start-date               readers#clear_start_date
GET    /community                readers#index   leaderboard
GET    /readers/:id              readers#show    a reader's progress + reflections
GET    /sign_in                  sessions#new     email form + provider list
POST   /sign_in/email            sessions#email_link      send a magic link
GET    /sign_in/email/:token     sessions#email_callback  consume a magic link
GET    /auth/:provider/callback  sessions#create  (OmniAuth callback)
POST   /auth/:provider/callback  sessions#create
GET    /auth/failure             sessions#failure
DELETE /sign_out                 sessions#destroy

POST   <mount>/auth/:provider    handled by the OmniAuth middleware, not the engine
```

## Tuning the plan shape

The whole schedule is derived from a handful of constants in `Bible270::Plan`, so the shape
can be changed without touching anything else:

| Constant | Default | Effect |
|----------|---------|--------|
| `DAYS` | `270` | plan length |
| `NT_PASSES` | `2` | how many times the New Testament is read (each pass gets `DAYS / NT_PASSES` days) |
| `PP_LONG_CHAPTER` | `100` | a chapter longer than this is divided. At 100 only Psalm 119 (176v) qualifies, since the next longest is Psalm 78 at 72v. Raise it above 176 to never split anything |
| `PP_SPLIT_PARTS` | `2` | how many readings such a chapter becomes |
| `PP_MIN_DAY` / `PP_DAY_TARGET` | `12` / `22` | how aggressively short chapters merge. These two values are what make the companion come out to exactly 135 portions, i.e. two clean passes across 270 days |

Everything is computed at load time and memoized; there is no generated schedule to migrate
if you change these.

## Scaling note

The community leaderboard computes completed-days in Ruby from grouped check-off
counts. That's ideal for a homelab/parish-sized community (hundreds of readers). If
you grow to many thousands, add a cached `days_completed` counter on `Reader`
(updated in a `Checkoff` after_commit) and sort in SQL.

## Development / tests

The deterministic plan logic is fully unit-tested with no Rails dependency:

```bash
bundle install
rake test
```

## License

MIT. See `MIT-LICENSE`.
