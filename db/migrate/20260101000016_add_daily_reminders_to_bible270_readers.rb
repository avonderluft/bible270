# frozen_string_literal: true

class AddDailyRemindersToBible270Readers < ActiveRecord::Migration[7.0]
  def change
    add_column :bible270_readers, :daily_reminders, :boolean, default: false, null: false
    add_column :bible270_readers, :daily_reminder_time, :string, default: '08:00', null: false
    add_column :bible270_readers, :last_daily_reminder_sent_on, :date
  end
end
