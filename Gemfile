# frozen_string_literal: true

source 'https://rubygems.org'
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

gemspec

group :development, :test do
  gem 'gem-release'
end

group :test do
  gem 'coveralls_reborn',         '~> 0.29.0', require: false
  gem 'minitest',                 '~> 6.0'
  gem 'minitest-reporters',       '>= 1.6.1'
  gem 'rubocop',                  '~> 1.88.2', require: false
  gem 'rubocop-minitest'
  gem 'rubocop-rails'
  gem 'simplecov', '~> 0.22.0', require: false
end
