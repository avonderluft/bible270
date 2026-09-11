# frozen_string_literal: true

require 'bible270/reader_progress_report'

namespace :bible270 do
  namespace :readers do
    desc 'List readers by completed days with their schedule status'
    task list: :environment do
      report = Bible270::ReaderProgressReport.new
      if report.empty?
        puts "No Bible270 readers found in the #{Rails.env} environment."
      else
        puts report.to_table
      end
    end
  end
end
