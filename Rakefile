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

desc 'Run tests in isolated processes (default: 2 workers)'
namespace :test do
  desc 'Run tests serially with coverage'
  Rake::TestTask.new(:serial) do |t|
    t.libs << 'test' << 'lib'
    t.pattern = 'test/**/*_test.rb'
    t.warning = false
  end

  task :parallel do
    workers = ENV.fetch('PARALLEL_WORKERS', '2')
    rm_rf 'coverage'
    env = {
      'PARALLEL_COVERAGE' => 'true',
      'RECORD_RUNTIME' => 'true',
      'SKIP_COV' => nil,
      'TMPDIR' => ENV.fetch('BIBLE270_TEST_TMPDIR', '/tmp')
    }
    command = ['bundle', 'exec', 'parallel_test', 'test', '--type', 'test', '-n', workers]
    sh env, *command

    require 'simplecov'
    result = SimpleCov::ResultMerger.merged_result
    puts format("\nLine Coverage: %<percent>.2f%% (%<covered>d / %<total>d)",
                percent: result.covered_percent, covered: result.covered_lines, total: result.total_lines)
  end
end

desc 'Run tests in parallel'
task test: 'test:parallel'
task default: :test
