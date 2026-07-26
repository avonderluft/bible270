# frozen_string_literal: true

ENV['RAILS_ENV'] = 'test'

require 'simplecov'

unless ENV['SKIP_COV']
  require 'coveralls'
  Coveralls.wear!('rails')
  SimpleCov.formatter = Coveralls::SimpleCov::Formatter
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
require "bible270/plan"
