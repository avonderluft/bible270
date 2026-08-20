# frozen_string_literal: true

require 'date'
require 'bible270/plan'

module Bible270
  # Delivers one reminder for each reader whose dated plan has an unfinished
  # reading and whose chosen local reminder time has arrived. Scheduling belongs
  # to the host application; repeated runs on the same local date are safe.
  module DailyReminders
  module_function

    def deliver(at: Time.now)
      return 0 unless Bible270.config.daily_reminders?

      unless Reader.daily_reminder_columns?
        Rails.logger.error(
          '[bible270] daily reminders unavailable: run bible270:install:migrations and db:migrate'
        )
        return 0
      end

      local_time = local_time_for(at)
      return 0 unless local_time.respond_to?(:to_date)

      date = local_time.to_date
      sent = 0
      Reader.daily_reminder_recipients(on: date).find_each do |reader|
        next unless reader.daily_reminder_due_at?(local_time)

        day = Plan.day_for(date, reader.effective_start_date, clamp: false)
        next unless Plan.valid_day?(day)
        next if reader.day_complete?(day)

        delivery = NoticeMailer.daily_reminder(reader_id: reader.id, day: day, on: date)
        next unless delivery.message.perform_deliveries

        delivery.deliver_now
        reader.update_column(:last_daily_reminder_sent_on, date)
        sent += 1
      rescue StandardError => e
        Rails.logger.error(
          "[bible270] daily reminder for reader #{reader.id} failed: #{e.class}: #{e.message}"
        )
      end
      sent
    end

    def local_time_for(at)
      return nil if at.nil?

      Bible270.local_time(at)
    rescue StandardError
      nil
    end
  end
end
