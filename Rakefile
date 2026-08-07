# frozen_string_literal: true

require 'coveralls/rake/task'
Coveralls::RakeTask.new

require 'bundler/gem_tasks' # provides build / install / release
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test' << 'lib'
  t.pattern = 'test/**/*_test.rb'
  t.warning = false
end

task default: :test
