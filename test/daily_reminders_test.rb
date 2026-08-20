# frozen_string_literal: true

require 'test_helper'
require 'bible270/daily_reminders'

if RAILS_LOADED
  class DailyRemindersTest < Minitest::Test
    FakeMessage = Struct.new(:perform_deliveries)

    class FakeDelivery
      attr_reader :message

      def initialize(fail: false)
        @fail = fail
        @message = FakeMessage.new(true)
      end

      def deliver_now
        raise 'mailbox unavailable' if @fail

        true
      end
    end

    def setup
      needs_rails!
      clear_engine_tables!
      ActionMailer::Base.deliveries.clear
      @at = Time.utc(2026, 9, 12, 8, 0)
      @on = Date.new(2026, 9, 12)
      @previous = {
        daily_reminders: Bible270.config.daily_reminders,
        start_date: Bible270.config.start_date,
        allow_reader_start_date: Bible270.config.allow_reader_start_date,
        time_zone: Bible270.config.time_zone,
        mailer_from: Bible270.config.mailer_from,
        mailer_host: Bible270.config.mailer_host
      }
      Bible270.config.daily_reminders = true
      Bible270.config.start_date = nil
      Bible270.config.allow_reader_start_date = true
      Bible270.config.time_zone = 'UTC'
      Bible270.config.mailer_from = 'no-reply@example.org'
      Bible270.config.mailer_host = 'example.org'
      @sequence = 0
    end

    def teardown
      Bible270.config.daily_reminders = @previous[:daily_reminders]
      Bible270.config.start_date = @previous[:start_date]
      Bible270.config.allow_reader_start_date = @previous[:allow_reader_start_date]
      Bible270.config.time_zone = @previous[:time_zone]
      Bible270.config.mailer_from = @previous[:mailer_from]
      Bible270.config.mailer_host = @previous[:mailer_host]
      ActionMailer::Base.deliveries.clear
    end

    def test_delivers_at_the_chosen_time_and_marks_the_local_date
      reader = create_reader(day: 7)

      assert_equal 1, Bible270::DailyReminders.deliver(at: @at)

      assert_equal @on, reader.reload.last_daily_reminder_sent_on
      assert_equal 1, ActionMailer::Base.deliveries.size
      assert_equal [reader.email], ActionMailer::Base.deliveries.last.to
      assert_match(%r{day 7}i, ActionMailer::Base.deliveries.last.subject)
    end

    def test_skips_a_reader_before_the_chosen_time
      reader = create_reader(day: 7, daily_reminder_time: '08:00')

      assert_equal 0, Bible270::DailyReminders.deliver(at: Time.utc(2026, 9, 12, 7, 59))
      assert_nil reader.reload.last_daily_reminder_sent_on
      assert_empty ActionMailer::Base.deliveries
    end

    def test_delivers_after_the_chosen_time
      reader = create_reader(day: 7, daily_reminder_time: '07:30')

      assert_equal 1, Bible270::DailyReminders.deliver(at: @at)
      assert_equal @on, reader.reload.last_daily_reminder_sent_on
    end

    def test_a_later_custom_time_is_not_due_yet
      reader = create_reader(day: 7, daily_reminder_time: '09:00')

      assert_equal 0, Bible270::DailyReminders.deliver(at: @at)
      assert_nil reader.reload.last_daily_reminder_sent_on
    end

    def test_configured_time_zone_controls_time_and_idempotency_date
      Bible270.config.time_zone = 'America/Los_Angeles'
      reader = create_reader(day: 7, daily_reminder_time: '17:00')
      # 00:30 UTC on September 13 is 17:30 on September 12 in Los Angeles.
      instant = Time.utc(2026, 9, 13, 0, 30)

      assert_equal 1, Bible270::DailyReminders.deliver(at: instant)
      assert_equal Date.new(2026, 9, 12), reader.reload.last_daily_reminder_sent_on
      assert_match(%r{day 7}i, ActionMailer::Base.deliveries.last.subject)
    end

    def test_a_second_run_on_the_same_local_date_is_idempotent
      reader = create_reader(day: 7)

      assert_equal 1, Bible270::DailyReminders.deliver(at: @at)
      assert_equal 0, Bible270::DailyReminders.deliver(at: @at + 3600)

      assert_equal @on, reader.reload.last_daily_reminder_sent_on
      assert_equal 1, ActionMailer::Base.deliveries.size
    end

    def test_global_switch_stops_delivery
      reader = create_reader(day: 1)
      Bible270.config.daily_reminders = false

      assert_equal 0, Bible270::DailyReminders.deliver(at: @at)
      assert_nil reader.reload.last_daily_reminder_sent_on
      assert_empty ActionMailer::Base.deliveries
    end

    def test_missing_daily_reminder_columns_log_the_required_migration_and_send_nothing
      messages = []
      log_error = ->(message) { messages << message }

      Bible270::Reader.stub(:daily_reminder_columns?, false) do
        Rails.logger.stub(:error, log_error) do
          assert_equal 0, Bible270::DailyReminders.deliver(at: @at)
        end
      end

      assert_includes messages,
                      '[bible270] daily reminders unavailable: run bible270:install:migrations and db:migrate'
      assert_empty ActionMailer::Base.deliveries
    end

    def test_skips_readers_who_are_not_opted_in_or_have_no_email
      opted_out = create_reader(day: 1, daily_reminders: false)
      no_email = create_reader(day: 1, email: nil)

      assert_equal 0, Bible270::DailyReminders.deliver(at: @at)
      assert_nil opted_out.reload.last_daily_reminder_sent_on
      assert_nil no_email.reload.last_daily_reminder_sent_on
      assert_empty ActionMailer::Base.deliveries
    end

    def test_skips_undated_readers
      reader = create_reader(day: nil)

      assert_equal 0, Bible270::DailyReminders.deliver(at: @at)
      assert_nil reader.reload.last_daily_reminder_sent_on
      assert_empty ActionMailer::Base.deliveries
    end

    def test_uses_unclamped_mapping_before_the_plan_starts
      reader = create_reader(day: nil, started_on: @on + 1)

      assert_equal 0, Bible270::DailyReminders.deliver(at: @at)
      assert_nil reader.reload.last_daily_reminder_sent_on
      assert_empty ActionMailer::Base.deliveries
    end

    def test_uses_unclamped_mapping_after_the_plan_ends
      reader = create_reader(day: nil, started_on: @on - Bible270::Plan::DAYS)

      assert_equal 0, Bible270::DailyReminders.deliver(at: @at)
      assert_nil reader.reload.last_daily_reminder_sent_on
      assert_empty ActionMailer::Base.deliveries
    end

    def test_skips_a_completed_day
      reader = create_reader(day: 3)
      reader.mark_day_complete!(3)

      assert_equal 0, Bible270::DailyReminders.deliver(at: @at)
      assert_nil reader.reload.last_daily_reminder_sent_on
      assert_empty ActionMailer::Base.deliveries
    end

    def test_skips_a_reader_already_marked_for_the_local_date
      reader = create_reader(day: 3, last_daily_reminder_sent_on: @on)

      assert_equal 0, Bible270::DailyReminders.deliver(at: @at)
      assert_equal @on, reader.reload.last_daily_reminder_sent_on
      assert_empty ActionMailer::Base.deliveries
    end

    def test_nil_or_invalid_timestamps_send_nothing
      create_reader(day: 3)

      assert_equal 0, Bible270::DailyReminders.deliver(at: nil)
      assert_equal 0, Bible270::DailyReminders.deliver(at: 'not a time')
      assert_empty ActionMailer::Base.deliveries
    end

    def test_one_delivery_failure_does_not_stop_other_readers
      failing = create_reader(day: 1)
      succeeding = create_reader(day: 1)
      deliveries = {
        failing.id => FakeDelivery.new(fail: true),
        succeeding.id => FakeDelivery.new
      }

      builder = ->(reader_id:, **) { deliveries.fetch(reader_id) }
      Bible270::NoticeMailer.stub(:daily_reminder, builder) do
        assert_equal 1, Bible270::DailyReminders.deliver(at: @at)
      end

      assert_nil failing.reload.last_daily_reminder_sent_on
      assert_equal @on, succeeding.reload.last_daily_reminder_sent_on
    end

    def test_the_date_is_not_marked_when_deliver_now_fails
      reader = create_reader(day: 1)
      delivery = FakeDelivery.new(fail: true)

      Bible270::NoticeMailer.stub(:daily_reminder, delivery) do
        assert_equal 0, Bible270::DailyReminders.deliver(at: @at)
      end

      assert_nil reader.reload.last_daily_reminder_sent_on
    end

  private

    def create_reader(day:, **attributes)
      @sequence += 1
      settings = {
        daily_reminders: true,
        daily_reminder_time: '08:00',
        last_daily_reminder_sent_on: nil
      }.merge(attributes)
      email = settings.delete(:email) { :default }
      started_on = settings.delete(:started_on) { :default }
      address = email == :default ? "reader#{@sequence}@example.org" : email
      start = if started_on == :default
                day ? @on - (day - 1) : nil
              else
                started_on
              end

      Bible270::Reader.create!(
        provider: address ? 'email' : 'owner',
        uid: address || "host-#{@sequence}",
        email: address,
        display_name: "Reader #{@sequence}",
        started_on: start,
        **settings
      )
    end
  end
end
