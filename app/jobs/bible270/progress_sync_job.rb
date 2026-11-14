# frozen_string_literal: true

require 'active_job'
require 'bible270/progress_sync'

module Bible270
  class ProgressSyncJob < ActiveJob::Base
    class EnqueueFailure < StandardError; end

    around_enqueue :sanitize_enqueue_failure

    def perform(delivery_id)
      return if delivery_id.nil?

      # Retry timing and claims live in the outbox. The scheduled rake task
      # recovers enqueue failures, expired leases, and transient delivery errors.
      ProgressSync.deliver_pending(delivery_id: delivery_id)
    end

  private

    # Active Job's enqueue instrumentation otherwise logs the adapter exception's
    # message before the model can rescue it; that message can contain credentials.
    def sanitize_enqueue_failure
      yield
      self.enqueue_error = EnqueueFailure.new(enqueue_error.class.name) if enqueue_error
    rescue StandardError => e
      raise EnqueueFailure, e.class.name, cause: nil
    end
  end
end
