# frozen_string_literal: true

require 'bundler/gem_tasks' # provides build / install / release
require 'rake/testtask'
require 'coveralls/rake/task'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test' << 'lib'
  t.pattern = 'test/**/*_test.rb'
  t.warning = false
end

Coveralls::RakeTask.new

task default: :test
