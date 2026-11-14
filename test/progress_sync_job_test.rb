# frozen_string_literal: true

require 'test_helper'
require 'bible270/progress_sync'

class ProgressSyncJobTest < Minitest::Test
  Sync = Bible270::ProgressSync
  Job = Bible270::ProgressSyncJob if RAILS_LOADED

  class DurableAdapter
    attr_reader :jobs

    def initialize
      @jobs = []
    end

    def enqueue(job)
      @jobs << job
    end

    def enqueue_at(job, _timestamp) = enqueue(job)
  end

  def run
    return super unless RAILS_LOADED

    config = Bible270.config.dup
    config.progress_sync_instance_id = 'source-instance'
    config.progress_sync_destinations = { 'church' => { url: 'https://church.example/bible', secret: 's' * 32 } }
    config.progress_sync_sources = {}
    config.progress_sync_deliver_later = true
    config.mention_notifications = false
    config.registration_notice_emails = []
    previous_adapter = Job.queue_adapter
    Job.queue_adapter = :test
    Bible270.stub(:config, config) { super }
  ensure
    Job.queue_adapter = previous_adapter if previous_adapter
  end

  def setup
    needs_rails!
    clear_engine_tables!
    @reader = Bible270::Reader.create!(provider: 'email', uid: 'source@example.org', email: 'source@example.org', display_name: 'Source')
    @membership = @reader.participation
    @link = Sync.link!(reader: @reader, destination: 'church', expected_participation_id: @membership.id,
                       remote: { 'reader_id' => 22, 'participation_id' => 33, 'generation' => 0, 'name' => 'Destination',
                                 'email' => 'dest@example.org', 'plan_fingerprint' => Sync.fingerprint })
  end

  def test_disabled_flag_does_not_enqueue_but_retains_outbox
    assert_equal false, Bible270::Configuration.new.progress_sync_deliver_later
    Bible270.config.progress_sync_deliver_later = false
    with_client(Object.new) { create_checkoff }
    assert_empty Job.queue_adapter.enqueued_jobs
    assert_equal 1, Bible270::ProgressSyncDelivery.count
    assert_equal 0, Bible270::ProgressSyncDelivery.sole.attempts
  end

  def test_test_adapter_enqueues_only_after_outer_commit_without_network
    with_client(Object.new) do
      Bible270::Checkoff.transaction do
        create_checkoff
        assert_equal 1, Bible270::ProgressSyncDelivery.count
        assert_empty Job.queue_adapter.enqueued_jobs
      end
    end
    delivery = Bible270::ProgressSyncDelivery.sole
    jobs = Job.queue_adapter.enqueued_jobs
    assert_equal 1, jobs.length
    assert_equal Job, jobs.first[:job]
    assert_equal [delivery.id], jobs.first[:args]
    assert_equal 0, delivery.attempts
    refute delivery.delivered?
  end

  def test_rollback_discards_outbox_and_does_not_enqueue
    Bible270::Checkoff.transaction do
      create_checkoff
      assert_equal 1, Bible270::ProgressSyncDelivery.count
      raise ActiveRecord::Rollback
    end
    assert_empty Job.queue_adapter.enqueued_jobs
    assert_empty Bible270::ProgressSyncDelivery.all
    assert_empty Bible270::Checkoff.all
  end

  def test_reader_bulk_insert_also_enqueues_only_after_commit
    Bible270::Reader.transaction do
      @reader.mark_day_complete!(1)
      assert_equal 1, Bible270::ProgressSyncDelivery.count
      assert_empty Job.queue_adapter.enqueued_jobs
    end
    assert_equal [Bible270::ProgressSyncDelivery.sole.id], Job.queue_adapter.enqueued_jobs.sole[:args]
    assert_equal 0, Bible270::ProgressSyncDelivery.sole.attempts
  end

  def test_host_durable_adapter_receives_delivery_id_not_reader_or_credentials
    adapter = DurableAdapter.new
    Job.queue_adapter = adapter
    create_checkoff
    assert_equal 1, adapter.jobs.length
    job = adapter.jobs.first
    assert_equal [Bible270::ProgressSyncDelivery.sole.id], job.arguments
    assert_equal 'default', job.queue_name
    refute Bible270::ProgressSyncDelivery.sole.delivered?
  end

  def test_inline_and_async_adapters_are_refused_with_actionable_warning
    %i[inline async].each_with_index do |adapter, index|
      Job.queue_adapter = adapter
      log = capture_warning do
        with_client(Object.new) { create_checkoff(day: index + 1) }
      end
      assert_match(adapter == :inline ? 'InlineAdapter' : 'AsyncAdapter', log)
      assert_match(%r{durable Active Job adapter and worker}, log)
      assert_match(%r{bible270:progress_sync:deliver every minute}, log)
    end
    assert_equal 2, Bible270::ProgressSyncDelivery.count
    assert_equal [0, 0], Bible270::ProgressSyncDelivery.order(:id).pluck(:attempts)
    assert_empty Bible270::ProgressSyncDelivery.where.not(delivered_at: nil)
  end

  def test_enqueue_exception_is_safely_logged_without_breaking_checkoff_and_scheduler_recovers
    secret = 'do-not-log-this-credential'
    log = capture_warning do
      Job.stub(:perform_later, ->(_id) { raise secret.to_s }) { create_checkoff }
    end
    assert_match('RuntimeError', log)
    refute_includes log, secret
    assert_match(%r{outbox retained}, log)
    assert_match(%r{bible270:progress_sync:deliver every minute}, log)
    assert_equal 1, Bible270::Checkoff.count
    delivery = Bible270::ProgressSyncDelivery.sole
    assert_equal 0, delivery.attempts
    with_client(success_client) { assert_equal 1, Sync.deliver_pending }
    assert delivery.reload.delivered?
  end

  def test_real_adapter_exceptions_do_not_leak_secret_messages_through_active_job_logging
    [RuntimeError, ActiveJob::EnqueueError].each_with_index do |error_class, index|
      adapter = DurableAdapter.new
      adapter.define_singleton_method(:enqueue) { |_job| raise error_class, 'secret-from-adapter-credentials' }
      Job.queue_adapter = adapter
      log = capture_warning { create_checkoff(day: index + 1) }
      assert_match('EnqueueFailure', log)
      refute_includes log, 'secret-from-adapter-credentials'
      assert_match(%r{outbox retained}, log)
    end
    assert_equal 2, Bible270::Checkoff.count
    assert_equal 2, Bible270::ProgressSyncDelivery.due.count
    assert_equal [0, 0], Bible270::ProgressSyncDelivery.order(:id).pluck(:attempts)
  end

  def test_enqueue_rejection_is_logged_and_outbox_remains_due
    log = capture_warning do
      Job.stub(:perform_later, false) { create_checkoff }
    end
    assert_match(%r{enqueue was not accepted}, log)
    assert_equal 1, Bible270::Checkoff.count
    assert_equal 1, Bible270::ProgressSyncDelivery.due.count
    assert_equal 0, Bible270::ProgressSyncDelivery.sole.attempts
  end

  def test_logging_failure_cannot_break_checkoff_after_enqueue_failure
    logger = Object.new
    logger.define_singleton_method(:warn) { |_message| raise IOError, 'logger failed' }
    Rails.stub(:logger, logger) do
      Job.stub(:perform_later, ->(_id) { raise 'enqueue failed' }) { create_checkoff }
    end
    assert_equal 1, Bible270::Checkoff.count
    assert_equal 1, Bible270::ProgressSyncDelivery.due.count
  end

  def test_job_delivers_only_its_target_and_duplicate_job_skips_successful_delivery
    create_checkoff
    first = Bible270::ProgressSyncDelivery.sole
    create_checkoff(day: 2)
    target = Bible270::ProgressSyncDelivery.order(:id).last
    calls = []
    client = completion_client do |_link, readings|
      refute ActiveRecord::Base.connection.transaction_open?
      calls << readings
      { 'added' => readings.length, 'existing' => 0 }
    end
    with_client(client) do
      assert_equal 1, Job.perform_now(target.id)
      assert_equal 0, Job.perform_now(target.id)
    end
    assert_equal [[[2, 'ot', 0]]], calls
    assert target.reload.delivered?
    assert_equal 1, target.attempts
    refute first.reload.delivered?
    assert_equal 0, first.attempts
  end

  def test_job_does_not_retry_a_transient_failure_before_outbox_backoff
    create_checkoff
    delivery = Bible270::ProgressSyncDelivery.sole
    with_client(completion_client { |_link, _readings| raise Sync::Unavailable, 'timeout' }) do
      assert_equal 0, Job.perform_now(delivery.id)
      assert_equal 0, Job.perform_now(delivery.id)
    end
    assert_equal 1, delivery.reload.attempts
    assert_operator delivery.next_attempt_at, :>, Time.current
    assert @link.reload.active?
    assert_equal 1, Job.queue_adapter.enqueued_jobs.length
    delivery.update!(next_attempt_at: Time.current - 1)
    with_client(success_client) { assert_equal 1, Sync.deliver_pending }
    assert delivery.reload.delivered?
    assert_equal 2, delivery.attempts
  end

  def test_job_skips_paused_link
    create_checkoff
    delivery = Bible270::ProgressSyncDelivery.sole
    @link.update!(state: 'paused')
    with_client(Object.new) { assert_equal 0, Job.perform_now(delivery.id) }
    assert_equal 0, delivery.reload.attempts
    refute delivery.delivered?
  end

  def test_job_skips_deleted_link_and_missing_delivery_id_without_sending_other_rows
    create_checkoff
    delivery = Bible270::ProgressSyncDelivery.sole
    @link.destroy!
    with_client(Object.new) do
      assert_equal 0, Job.perform_now(delivery.id)
      assert_nil Job.perform_now(nil)
    end
    assert_empty Bible270::ProgressSyncDelivery.all
  end

  def test_job_pauses_stale_membership_even_if_reader_reactivated_before_job_runs
    create_checkoff
    delivery = Bible270::ProgressSyncDelivery.sole
    @reader.archive!
    @reader.activate!
    with_client(Object.new) { assert_equal 0, Job.perform_now(delivery.id) }
    assert @link.reload.paused?
    assert_match(%r{generation}, @link.last_error)
    refute delivery.reload.delivered?
  end

  def test_job_does_not_steal_an_unexpired_worker_lease
    create_checkoff
    delivery = Bible270::ProgressSyncDelivery.sole
    delivery.update!(claim_token: 'other-worker', locked_until: Time.current + 300)
    with_client(Object.new) { assert_equal 0, Job.perform_now(delivery.id) }
    assert_equal 'other-worker', delivery.reload.claim_token
    assert_equal 0, delivery.attempts
  end

  def test_targeted_engine_filter_does_not_send_other_deliveries_for_unknown_id
    create_checkoff
    delivery = Bible270::ProgressSyncDelivery.sole
    with_client(Object.new) { assert_equal 0, Sync.deliver_pending(delivery_id: delivery.id + 1) }
    assert_equal 0, delivery.reload.attempts
    refute delivery.delivered?
  end

private

  def create_checkoff(day: 1)
    Bible270::Checkoff.create!(reader: @reader, participation: @membership, day: day, track: 'ot', part: 0)
  end

  def completion_client(&block)
    Object.new.tap { |client| client.define_singleton_method(:complete) { |*args| block.call(*args) } }
  end

  def success_client
    completion_client do |_link, readings|
      refute ActiveRecord::Base.connection.transaction_open?
      { 'added' => readings.length, 'existing' => 0 }
    end
  end

  def with_client(client, &)
    Sync::Client.stub(:new, client, &)
  end

  def capture_warning(&)
    output = StringIO.new
    previous_logger = Job.logger
    Job.logger = Logger.new(output)
    Rails.stub(:logger, Job.logger, &)
    output.string
  ensure
    Job.logger = previous_logger
  end
end
