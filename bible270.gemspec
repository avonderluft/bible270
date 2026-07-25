# frozen_string_literal: true
require_relative "lib/bible270/version"

Gem::Specification.new do |spec|
  spec.name        = "bible270"
  spec.version     = Bible270::VERSION
  spec.authors     = ["Andrew vonderLuft"]
  spec.email       = ["wonder@hey.com"]
  spec.summary     = "A mountable Rails engine: a 270-day, verse-balanced Bible reading plan (OT once, NT twice, Psalms/Proverbs alongside) with per-user check-offs, comments, and shared community progress."
  spec.description = "Drop-in Rails engine that adds a social daily Bible reading plan over 270 days: the Old Testament once, the New Testament twice, and a whole-chapter Psalms/Proverbs companion. Daily portions are balanced by verse count so each day takes about the same time to read, and chapters are never split except Psalm 119. Readers check off each day's readings, leave reflections, and see one another's progress. Designed to mount cleanly into a host Rails app such as ComfortableMediaSurfer."
  spec.homepage    = "https://gknt.org"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/avonderluft/bible270"
  spec.metadata["bug_tracker_uri"] = "https://github.com/avonderluft/bible270/issues"
  spec.metadata["changelog_uri"]   = "https://github.com/avonderluft/bible270/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "app/**/*", "config/**/*", "db/**/*", "lib/**/*",
    "MIT-LICENSE", "Rakefile", "README.md", "CHANGELOG.md"
  ]
  spec.require_paths = ["lib"]

  spec.add_dependency "rails", ">= 7.0"

  # Built-in sign-in. OmniAuth 2.0+ is required: it disallows GET on the request
  # phase (CVE-2015-9284), which is what the engine's POST sign-in forms assume.
  # The provider strategy gems (omniauth-github etc.) are the host app's choice.
  spec.add_dependency "omniauth", ">= 2.0"
  spec.add_dependency "omniauth-rails_csrf_protection", ">= 1.0"

  spec.add_development_dependency "minitest", "~> 5.0"
end
