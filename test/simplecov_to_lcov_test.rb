# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'open3'
require 'tmpdir'

class SimpleCovToLcovTest < Minitest::Test
  def test_it_emits_only_executable_lines_and_reports_the_same_total
    output, lcov = convert(
      'Unit Tests' => {
        'coverage' => {
          File.join(Dir.pwd, 'lib/example.rb') => { 'lines' => [nil, 3, 0, nil, 1] }
        }
      }
    )

    assert_includes output, 'LCOV COVERAGE: 2 / 3 = 66.67%'
    assert_includes lcov, "SF:lib/example.rb\n"
    assert_includes lcov, "DA:2,3\n"
    assert_includes lcov, "DA:3,0\n"
    assert_includes lcov, "DA:5,1\n"
    assert_includes lcov, "LF:3\nLH:2\n"
    refute_includes lcov, 'DA:1,'
    refute_includes lcov, 'DA:4,'
  end

  def test_it_combines_multiple_simplecov_command_results
    path = File.join(Dir.pwd, 'lib/example.rb')
    _output, lcov = convert(
      'Unit Tests' => { 'coverage' => { path => { 'lines' => [nil, 1, 0] } } },
      'Integration Tests' => { 'coverage' => { path => { 'lines' => [nil, 2, 4, 1] } } }
    )

    assert_includes lcov, "DA:2,3\n"
    assert_includes lcov, "DA:3,4\n"
    assert_includes lcov, "DA:4,1\n"
    assert_equal 1, lcov.scan('SF:lib/example.rb').size
  end

private

  def convert(resultset)
    Dir.mktmpdir do |dir|
      input = File.join(dir, 'resultset.json')
      output = File.join(dir, 'lcov.info')
      File.write(input, JSON.generate(resultset))

      stdout, stderr, status = Open3.capture3(
        'ruby', File.expand_path('../script/simplecov_to_lcov.rb', __dir__), input, output
      )
      assert status.success?, stderr
      return [stdout, File.read(output)]
    end
  end
end
