# frozen_string_literal: true

require 'json'
require 'pathname'

resultset_path = ARGV.fetch(0, 'coverage/.resultset.json')
output_path = ARGV.fetch(1, 'coverage/lcov.info')
root = Pathname.new(Dir.pwd).realpath
resultset = JSON.parse(File.read(resultset_path))

coverage = resultset.values.each_with_object({}) do |result, combined|
  result.fetch('coverage').each do |path, file_coverage|
    lines = file_coverage.fetch('lines')
    existing = combined[path]
    combined[path] = if existing
                       [existing.length, lines.length].max.times.map do |index|
                         counts = [existing[index], lines[index]].compact
                         counts.empty? ? nil : counts.sum
                       end
                     else
                       lines
                     end
  end
end

covered = 0
total = 0
File.open(output_path, 'w') do |lcov|
  coverage.sort.each do |path, lines|
    source = Pathname.new(path)
    source = source.relative_path_from(root) if source.absolute? && source.to_s.start_with?("#{root}/")
    lcov.puts "SF:#{source}"

    lines.each_with_index do |hits, index|
      next if hits.nil?

      total += 1
      covered += 1 if hits.positive?
      lcov.puts "DA:#{index + 1},#{hits}"
    end

    lcov.puts "LF:#{lines.compact.length}"
    lcov.puts "LH:#{lines.compact.count(&:positive?)}"
    lcov.puts 'end_of_record'
  end
end

percentage = total.zero? ? 100.0 : (covered.to_f / total * 100)
puts "LCOV COVERAGE: #{covered} / #{total} = #{percentage.round(2)}%"
