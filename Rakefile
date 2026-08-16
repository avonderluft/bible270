# frozen_string_literal: true

require 'bundler/gem_tasks' # provides build / install / release
require 'rake/testtask'

desc 'Normalize permissions for files included in the gem'
task :normalize_gem_permissions do
  spec = Gem::Specification.load('bible270.gemspec')
  spec.files.each do |path|
    File.chmod(0o644, path) if File.file?(path)
  end
end

Rake::Task[:build].enhance([:normalize_gem_permissions])

Rake::TestTask.new(:test) do |t|
  t.libs << 'test' << 'lib'
  t.pattern = 'test/**/*_test.rb'
  t.warning = false
end

task default: :test
