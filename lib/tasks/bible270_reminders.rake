# frozen_string_literal: true

require 'bible270/daily_reminders'

namespace :bible270 do
  namespace :reminders do
    desc 'Send Bible270 reminders now due at each opted-in reader time'
    task send: :environment do
      count = Bible270::DailyReminders.deliver
      puts "Sent #{count} daily reading #{'reminder'.pluralize(count)}."
    end
  end
end
