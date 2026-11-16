# frozen_string_literal: true

require_relative 'support/progress_sync_test_case'

class ProgressSyncDeliveryTest < Bible270ProgressSyncTestCase
  def test_stale_run_is_rejected_before_delivery_without_network
    link = create_link
    delivery = Sync.capture(@membership, [[1, 'ot', 0]]).first
    @membership.plan_run.update!(current: nil)
    with_client(Object.new) { assert_equal 0, Sync.deliver_pending }
    assert link.reload.paused?
    assert_nil delivery.reload.delivered_at
    assert_match(%r{linked run}, delivery.last_error)
  end

  def test_response_count_sum_must_match_delivery_before_marking_success
    link = create_link
    add_checkoff
    delivery = Bible270::ProgressSyncDelivery.sole
    with_client(completion_client { |_link, _readings| { 'added' => 0, 'existing' => 0 } }) do
      assert_equal 0, Sync.deliver_pending
    end
    refute delivery.reload.delivered?
    assert_equal 1, delivery.attempts
    assert_operator delivery.next_attempt_at, :>, Time.current
    assert_match(%r{invalid completion counts}, delivery.last_error)
    assert link.reload.active?
    assert_nil link.last_synced_at
    assert_nil link.last_added
  end

  def test_response_count_sum_uses_unique_readings
    link = create_link
    add_checkoff
    delivery = Bible270::ProgressSyncDelivery.sole
    delivery.update!(readings: [[1, 'ot', 0], [1, 'ot', 0]])
    with_client(completion_client { |_link, _readings| { 'added' => 1, 'existing' => 0 } }) do
      assert_equal 1, Sync.deliver_pending
    end
    assert delivery.reload.delivered?
    assert_equal 1, link.reload.last_added
  end

  def test_transient_failure_backs_off_then_succeeds
    link = create_link
    delivery = Sync.capture(@membership, [[1, 'ot', 0]]).first
    with_client(completion_client { |_link, _readings| raise Sync::Unavailable, 'timeout' }) do
      assert_equal 0, Sync.deliver_pending
      assert_equal 0, Sync.deliver_pending
    end
    delivery.reload
    assert_equal 1, delivery.attempts
    assert_operator delivery.next_attempt_at, :>, Time.current
    assert_nil delivery.claim_token
    assert link.reload.active?
    assert_equal 'timeout', link.last_error
    delivery.update!(next_attempt_at: Time.current - 1)
    with_client(completion_client { |_link, _readings| { 'added' => 1, 'existing' => 0 } }) do
      assert_equal 1, Sync.deliver_pending
    end
    assert_equal 2, delivery.reload.attempts
    assert delivery.delivered?
    assert_nil link.reload.last_error
    assert_equal 1, link.last_added
  end

  def test_permanent_errors_pause_and_stop_other_pending_deliveries
    [Sync::Conflict, Sync::Unauthorized, Sync::ConfigurationError].each do |error_class|
      Bible270::ProgressSyncDelivery.delete_all
      Bible270::ProgressSyncLink.delete_all
      link = create_link
      2.times { Sync.capture(@membership, [[1, 'ot', 0]]) }
      calls = 0
      with_client(completion_client do |_link, _readings|
        calls += 1
        raise error_class, 'cannot sync'
      end) do
        assert_equal 0, Sync.deliver_pending
        assert_equal 0, Sync.deliver_pending
      end
      assert_equal 1, calls
      assert link.reload.paused?
      assert_equal 'cannot sync', link.last_error
      assert_nil link.last_synced_at
    end
  end

  def test_retry_budget_is_bounded_per_delivery
    link = create_link
    delivery = Sync.capture(@membership, [[1, 'ot', 0]]).first
    calls = 0
    with_client(completion_client do |_link, _readings|
      calls += 1
      raise Sync::Unavailable, 'still offline'
    end) do
      (Sync::MAX_ATTEMPTS + 2).times do
        delivery.update!(next_attempt_at: Time.current - 1)
        Sync.deliver_pending
      end
    end
    assert_equal Sync::MAX_ATTEMPTS, calls
    assert_equal Sync::MAX_ATTEMPTS, delivery.reload.attempts
    assert link.reload.paused?
    refute delivery.delivered?
  end

  def test_interleaved_workers_cannot_claim_the_same_delivery
    create_link
    delivery = Sync.capture(@membership, [[1, 'ot', 0]]).first
    finder = Bible270::ProgressSyncDelivery.method(:find_by)
    competing = nil
    entered = false
    # Force both workers to read the unclaimed row before the first worker's
    # CAS. This is deterministic on the test suite's in-memory SQLite database.
    Bible270::ProgressSyncDelivery.stub(:find_by, ->(*args, **kwargs) {
      snapshot = finder.call(*args, **kwargs)
      unless entered
        entered = true
        competing = Sync.send(:claim_delivery, delivery.id)
      end
      snapshot
    }) do
      assert_nil Sync.send(:claim_delivery, delivery.id)
    end
    assert competing
    assert_equal 1, delivery.reload.attempts
    assert_nil Sync.send(:claim_delivery, delivery.id)
  end

  def test_expired_lease_is_reclaimable_and_late_worker_cannot_finish_it
    link = create_link
    delivery = Sync.capture(@membership, [[1, 'ot', 0]]).first
    old, = Sync.send(:claim_delivery, delivery.id)
    delivery.update!(locked_until: Time.current - 1)
    current, = Sync.send(:claim_delivery, delivery.id)
    refute_equal old.claim_token, current.claim_token
    refute Sync.send(:finish_delivery!, old, counts: [1, 0])
    assert_nil delivery.reload.delivered_at
    assert_nil link.reload.last_synced_at
    assert Sync.send(:finish_delivery!, current, counts: [0, 1])
    assert delivery.reload.delivered?
    assert_equal 2, delivery.attempts
  end

  def test_link_deleted_after_claim_is_a_permanent_conflict_not_a_worker_crash
    link = create_link
    delivery = Sync.capture(@membership, [[1, 'ot', 0]]).first
    claimed, = Sync.send(:claim_delivery, delivery.id)
    link.destroy!
    assert_raises(Sync::Conflict) { Sync.send(:prepare_delivery!, claimed) }
    refute Sync.send(:finish_delivery!, claimed, error: Sync::Conflict.new('deleted'))
    assert_empty Bible270::ProgressSyncDelivery.all
  end

  def test_worker_crashes_cannot_create_an_unlimited_retry_budget
    link = create_link
    delivery = Sync.capture(@membership, [[1, 'ot', 0]]).first
    delivery.update!(attempts: Sync::MAX_ATTEMPTS, claim_token: 'dead-worker', locked_until: Time.current - 1)
    with_client(Object.new) { assert_equal 0, Sync.deliver_pending }
    assert link.reload.paused?
    assert_match(%r{retry limit}, link.last_error)
    assert_equal Sync::MAX_ATTEMPTS, delivery.reload.attempts
  end

  def test_late_success_or_transient_failure_cannot_erase_a_permanent_pause
    link = create_link
    first = Sync.capture(@membership, [[1, 'ot', 0]]).first
    second = Sync.capture(@membership, [[2, 'ot', 0]]).first
    third = Sync.capture(@membership, [[3, 'ot', 0]]).first
    claimed = [first, second, third].map { |delivery| Sync.send(:claim_delivery, delivery.id).first }
    Sync.send(:finish_delivery!, claimed[0], error: Sync::Unauthorized.new('Credentials revoked'))
    Sync.send(:finish_delivery!, claimed[1], counts: [1, 0])
    Sync.send(:finish_delivery!, claimed[2], error: Sync::Unavailable.new('late timeout'))
    assert link.reload.paused?
    assert_equal 'Credentials revoked', link.last_error
    assert_equal 1, link.last_added
    assert link.last_synced_at
  end

  def test_stale_generation_is_rechecked_before_network_even_without_capture
    link = create_link
    delivery = Sync.capture(@membership, [[1, 'ot', 0]]).first
    @membership.update!(progress_sync_generation: @membership.progress_sync_generation + 1)
    with_client(Object.new) { assert_equal 0, Sync.deliver_pending }
    assert link.reload.paused?
    assert_nil delivery.reload.delivered_at
    assert_match(%r{generation}, link.last_error)
  end

  def test_scheduled_rake_task_prints_successful_delivery_count
    require 'rake'
    previous = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load File.expand_path('../lib/tasks/bible270_progress_sync.rake', __dir__)
    Sync.stub(:deliver_pending, 2) do
      assert_output("Delivered 2 progress sync deliveries.\n") do
        Rake::Task['bible270:progress_sync:deliver'].invoke
      end
    end
  ensure
    Rake.application = previous if previous
  end
end
