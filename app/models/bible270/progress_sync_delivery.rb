# frozen_string_literal: true

module Bible270
  class ProgressSyncDelivery < ApplicationRecord
    self.table_name = 'bible270_progress_sync_deliveries'

    belongs_to :progress_sync_link, class_name: 'Bible270::ProgressSyncLink', inverse_of: :deliveries

    after_create_commit :enqueue_immediate_delivery

    validates :readings, presence: true
    validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :next_attempt_at, presence: true

    scope :pending, -> { where(delivered_at: nil) }
    scope :due, ->(now = Time.current) {
      pending.where('next_attempt_at <= ?', now).where('locked_until IS NULL OR locked_until <= ?', now)
    }

    def delivered? = delivered_at.present?

  private

    def enqueue_immediate_delivery
      return unless Bible270.config.progress_sync_deliver_later

      adapter = ProgressSyncJob.queue_adapter
      if adapter.is_a?(ActiveJob::QueueAdapters::InlineAdapter) || adapter.is_a?(ActiveJob::QueueAdapters::AsyncAdapter)
        warn_delivery_enqueue("Immediate delivery skipped: #{adapter.class.name} is not a durable worker adapter.")
        return
      end

      unless ProgressSyncJob.perform_later(id)
        warn_delivery_enqueue('Immediate delivery enqueue was not accepted.')
      end
    rescue StandardError => e
      warn_delivery_enqueue("Immediate delivery enqueue failed (#{e.class.name}).")
    end

    def warn_delivery_enqueue(detail)
      message = "[Bible270] #{detail} Progress sync outbox retained; configure a durable Active Job adapter and worker, " \
                'and schedule bible270:progress_sync:deliver every minute as fallback.'
      sync_logger = defined?(Rails) && Rails.logger
      sync_logger ||= self.class.logger
      sync_logger ? sync_logger.warn(message) : warn(message)
    rescue StandardError
      # Logging and optional enqueue failures must never invalidate a checkoff.
      nil
    end
  end
end
