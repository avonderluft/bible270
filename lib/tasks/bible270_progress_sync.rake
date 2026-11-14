# frozen_string_literal: true

require 'bible270/progress_sync'

namespace :bible270 do
  namespace :progress_sync do
    desc 'Deliver due one-way Bible270 progress sync outbox entries (schedule regularly)'
    task deliver: :environment do
      count = Bible270::ProgressSync.deliver_pending
      puts "Delivered #{count} progress sync #{'delivery'.pluralize(count)}."
    end
  end
end
