# frozen_string_literal: true

require 'bible270/migration_reconciler'

namespace :bible270 do
  namespace :migrations do
    desc 'Reconcile copied Bible270/Active Storage tables with schema_migrations (set APPLY=1 to write)'
    task reconcile: :environment do
      reconciler = Bible270::MigrationReconciler.for_current_database
      statuses = reconciler.statuses

      if statuses.empty?
        puts 'No pending Bible270 or related Active Storage migrations were found.'
        next
      end

      complete, incomplete = statuses.partition(&:complete?)

      puts 'Already reflected in the database schema:'
      if complete.empty?
        puts '  (none)'
      else
        complete.each do |status|
          puts "  #{status.migration.version} #{status.migration.name}"
        end
      end

      unless incomplete.empty?
        puts
        puts 'Still missing schema changes (these will remain pending):'
        incomplete.each do |status|
          puts "  #{status.migration.version} #{status.migration.name}"
          status.missing.each { |item| puts "    - #{item}" }
        end
      end

      puts
      unless ENV['APPLY'] == '1'
        puts 'Preview only; schema_migrations was not changed.'
        puts 'Review the list, back up the database, then rerun with APPLY=1.'
        next
      end

      if complete.empty?
        puts 'Nothing was safe to mark as applied.'
        next
      end

      ActiveRecord::Base.transaction do
        complete.each { |status| reconciler.mark_applied!(status) }
      end

      puts "Marked #{complete.size} verified #{'migration'.pluralize(complete.size)} as applied."
      puts 'Run bin/rails db:migrate to apply the migrations whose schema changes are still missing.'
    end
  end
end
