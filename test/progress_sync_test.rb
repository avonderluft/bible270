# frozen_string_literal: true

require 'test_helper'
require 'bible270/progress_sync'

class ProgressSyncTest < Minitest::Test
  Sync = Bible270::ProgressSync

  # Use the native configuration API without leaking settings into other tests.
  def run
    return super unless RAILS_LOADED

    config = Bible270.config.dup

    config.progress_sync_instance_id = 'source-instance'
    config.progress_sync_destinations = { 'church' => { label: 'Church', url: 'https://church.example/bible', secret: 's' * 32 } }
    config.progress_sync_sources = {}
    config.progress_sync_deliver_later = false
    config.admin_emails = []
    config.admin_resolver = nil
    config.mention_notifications = false
    config.registration_notice_emails = []
    Bible270.stub(:config, config) { super }
  end

  def setup
    needs_rails!
    Bible270::ProgressSyncDelivery.delete_all
    Bible270::ProgressSyncLink.delete_all
    clear_engine_tables!
    @reader = Bible270::Reader.create!(provider: 'email', uid: 'source@example.org', email: 'source@example.org', display_name: 'Source')
    @membership = @reader.participation
    @remote = { 'reader_id' => 22, 'participation_id' => 33, 'generation' => 0,
                'name' => 'Destination Reader', 'email' => ' DEST@example.org ', 'plan_fingerprint' => Sync.fingerprint }
  end

  def test_schema_and_fingerprint_are_available_and_schedule_sensitive
    assert Sync.available?
    original = Sync.fingerprint
    assert_match(%r{\A[0-9a-f]{64}\z}, original)
    assert_equal original, Sync.fingerprint
    parts = Bible270::Plan.method(:parts_for)
    Bible270::Plan.stub(:parts_for, ->(day, track) { day == 1 && track == 'ot' ? ['Different passage'] : parts.call(day, track) }) do
      refute_equal original, Sync.fingerprint
    end
    assert_equal original, Sync.fingerprint
  end

  def test_suppression_is_nested_thread_local_and_restored_on_error
    refute Sync.suppressed?
    assert_raises(RuntimeError) do
      Sync.suppress do
        assert Sync.suppressed?
        Sync.suppress { assert Sync.suppressed? }
        assert Sync.suppressed?
        refute Thread.new { Sync.suppressed? }.value
        raise 'import failed'
      end
    end
    refute Sync.suppressed?
  end

  def test_lookup_normalizes_email_and_only_proxies_the_allowlisted_client
    calls = []
    client = Object.new
    client.define_singleton_method(:lookup) do |email|
      calls << email
      @remote_payload
    end
    client.instance_variable_set(:@remote_payload, @remote)
    with_client(client) do
      assert_equal @remote, Sync.lookup(destination: 'church', email: ' DEST@EXAMPLE.ORG ')
      assert_raises(Sync::ConfigurationError) { Sync.lookup(destination: 'unknown', email: 'dest@example.org') }
    end
    assert_equal ['dest@example.org'], calls
  end

  def test_link_pins_target_and_normalizes_email_and_duplicate_is_invalid
    link = create_link
    assert_equal 'dest@example.org', link.email
    assert_equal 'https://church.example/bible', link.destination_url
    assert_equal @membership.progress_sync_generation, link.source_generation
    assert_equal 33, link.remote_participation_id
    assert_equal 'Destination Reader', link.remote_name
    assert link.usable?
    assert_equal 'Ready', link.status
    assert_raises(ActiveRecord::RecordInvalid) { create_link }
    assert_equal 1, Bible270::ProgressSyncLink.count
  end

  def test_stale_or_inactive_memberships_and_wrong_plan_cannot_be_linked
    assert_raises(Sync::Conflict) { create_link(expected_participation_id: -1) }
    assert_raises(Sync::Conflict) { create_link(remote: @remote.merge('plan_fingerprint' => 'wrong')) }
    @membership.update!(active: false)
    assert_raises(Sync::Conflict) { create_link }
    assert_empty Bible270::ProgressSyncLink.all
  end

  def test_capture_has_no_network_and_deduplicates_payload
    link = create_link
    with_client(Object.new) do
      deliveries = Sync.capture(@membership, [[1, 'ot', 0], [1, 'ot', 0]])
      assert_equal 1, deliveries.length
      assert_equal [[1, 'ot', 0]], deliveries.first.readings
    end
    assert_equal 'Pending', link.status
  end

  def test_actual_checkoff_create_captures_once_without_network
    link = create_link
    with_client(Object.new) { add_checkoff }
    delivery = Bible270::ProgressSyncDelivery.sole
    assert_equal link.id, delivery.progress_sync_link_id
    assert_equal [[1, 'ot', 0]], delivery.readings
    assert_equal 0, delivery.attempts
    assert_raises(ActiveRecord::RecordInvalid) { add_checkoff }
    assert_equal 1, Bible270::ProgressSyncDelivery.count
  end

  def test_reader_bulk_completion_captures_once_and_clearing_does_not_forward
    create_link
    expected = Bible270::Plan.present_tracks(1).flat_map do |track|
      (0...Bible270::Plan.part_count(1, track)).map { |part| [1, track, part] }
    end
    with_client(Object.new) do
      @reader.mark_day_complete!(1)
      assert_equal expected, Bible270::ProgressSyncDelivery.sole.readings
      assert_equal expected.length, @reader.checkoffs.count
      @reader.mark_day_complete!(1)
      assert_equal 1, Bible270::ProgressSyncDelivery.count
      @reader.clear_day!(1)
      assert_empty @reader.checkoffs
      assert_equal 1, Bible270::ProgressSyncDelivery.count
    end
  end

  def test_reader_bulk_completion_and_outbox_rollback_together
    create_link
    Bible270::Reader.transaction do
      @reader.mark_day_complete!(1)
      assert_operator @reader.checkoffs.count, :>, 0
      assert_equal 1, Bible270::ProgressSyncDelivery.count
      raise ActiveRecord::Rollback
    end
    assert_empty Bible270::Checkoff.all
    assert_empty Bible270::ProgressSyncDelivery.all
  end

  def test_client_autoloads_with_only_the_core_required
    require 'open3'
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-I', File.expand_path('../lib', __dir__),
                                            '-rbible270/progress_sync', '-e', 'puts Bible270::ProgressSync::Client.name')
    assert status.success?, stderr
    assert_equal "Bible270::ProgressSync::Client\n", stdout
  end

  def test_capture_is_atomic_with_local_checkoff_rollback
    create_link
    Bible270::Checkoff.transaction do
      add_checkoff
      assert_equal 1, Bible270::ProgressSyncDelivery.count
      raise ActiveRecord::Rollback
    end
    assert_empty Bible270::Checkoff.all
    assert_empty Bible270::ProgressSyncDelivery.all
  end

  def test_imported_progress_never_forwards_and_nested_suppression_restores
    create_link
    Sync.suppress do
      add_checkoff
      assert_empty Sync.capture(@membership, [[1, 'ot', 0]])
    end
    assert_equal 1, Bible270::Checkoff.count
    assert_empty Bible270::ProgressSyncDelivery.all
    add_checkoff(day: 2)
    assert_equal [[2, 'ot', 0]], Bible270::ProgressSyncDelivery.sole.readings
  end

  def test_capture_without_destination_or_migration_is_a_noop
    create_link
    previous = Bible270.config.progress_sync_destinations
    Bible270.config.progress_sync_destinations = {}
    assert_empty Sync.capture(@membership, [[1, 'ot', 0]])
    Bible270.config.progress_sync_destinations = previous
    connection = ActiveRecord::Base.connection
    exists = connection.method(:data_source_exists?)
    connection.stub(:data_source_exists?, ->(table) { table.to_s == 'bible270_progress_sync_deliveries' ? false : exists.call(table) }) do
      refute Sync.available?
      assert_empty Sync.capture(@membership, [[1, 'ot', 0]])
      assert_equal 0, Sync.deliver_pending
    end
    column_exists = connection.method(:column_exists?)
    connection.stub(:column_exists?, ->(table, column, *args) {
      column.to_s == 'progress_sync_generation' ? false : column_exists.call(table, column, *args)
    }) do
      refute Sync.available?
      assert_empty Sync.capture(@membership, [[1, 'ot', 0]])
    end
    assert_empty Bible270::ProgressSyncDelivery.all
  end

  def test_source_generation_changes_never_silently_resume_after_reactivation
    link = create_link
    generation = @membership.progress_sync_generation
    @reader.archive!
    assert_equal generation + 1, @membership.reload.progress_sync_generation
    @reader.activate!
    assert_equal generation + 1, @membership.reload.progress_sync_generation
    assert_empty Sync.capture(@membership, [[1, 'ot', 0]])
    assert link.reload.paused?
    assert_equal 'Needs attention', link.status
    assert_match(%r{generation}, link.last_error)
    assert_empty Sync.capture(@membership, [[1, 'ot', 0]])
  end

  def test_run_change_and_revert_leave_old_link_stale
    link = create_link
    generation = @membership.progress_sync_generation
    new_run = Bible270::PlanRun.restart!(start_date: Bible270.today + 1, expected_run_id: @membership.plan_run_id)
    assert_equal generation + 1, @membership.reload.progress_sync_generation
    refute @membership.active?
    Bible270::PlanRun.revert!(expected_run_id: new_run.id)
    assert @membership.reload.active?
    assert_equal generation + 1, @membership.progress_sync_generation
    assert @membership.plan_run.reload.current?
    assert_raises(Sync::Conflict) { Sync.copy_existing!(link) }
    assert link.reload.paused?
    assert_empty Bible270::ProgressSyncDelivery.all
  end

  def test_stale_run_is_rejected_before_delivery_without_network
    link = create_link
    delivery = Sync.capture(@membership, [[1, 'ot', 0]]).first
    @membership.plan_run.update!(current: nil)
    with_client(Object.new) { assert_equal 0, Sync.deliver_pending }
    assert link.reload.paused?
    assert_nil delivery.reload.delivered_at
    assert_match(%r{linked run}, delivery.last_error)
  end

  def test_repointed_destination_pauses_link_and_remains_paused_after_revert
    link = create_link
    delivery = Sync.capture(@membership, [[1, 'ot', 0]]).first
    Bible270.config.progress_sync_destinations['church'][:url] = 'https://other.example/bible'
    with_client(Object.new) { assert_equal 0, Sync.deliver_pending }
    assert link.reload.paused?
    assert_match(%r{URL changed}, link.last_error)
    Bible270.config.progress_sync_destinations['church'][:url] = link.destination_url
    refute link.reload.usable?
    assert_empty Sync.capture(@membership, [[1, 'ot', 0]])
    assert_nil delivery.reload.delivered_at
  end

  def test_plan_change_pauses_capture
    link = create_link
    Sync.stub(:fingerprint, 'different-plan') do
      assert_empty Sync.capture(@membership, [[1, 'ot', 0]])
    end
    assert link.reload.paused?
    assert_match(%r{plan changed}, link.last_error)
  end

  def test_explicit_relink_creates_new_target_without_retargeting_old_deliveries
    old = create_link
    queued = Sync.capture(@membership, [[1, 'ot', 0]]).first
    old.update!(state: 'paused')
    replacement = create_link(remote: @remote.merge('reader_id' => 44, 'participation_id' => 55))
    refute_equal old.id, replacement.id
    assert_equal old.id, queued.reload.progress_sync_link_id
    assert_equal 33, old.reload.remote_participation_id
    assert_equal 55, replacement.remote_participation_id
    with_client(Object.new) { assert_equal 0, Sync.deliver_pending }
  end

  def test_remote_generation_change_replaces_active_binding_with_empty_outbox
    assert_remote_binding_replacement('generation', 1, pending: false)
  end

  def test_remote_generation_change_replaces_active_binding_with_pending_delivery
    assert_remote_binding_replacement('generation', 1, pending: true)
  end

  def test_remote_membership_change_replaces_active_binding_with_empty_outbox
    assert_remote_binding_replacement('participation_id', 44, pending: false)
  end

  def test_remote_membership_change_replaces_active_binding_with_pending_delivery
    assert_remote_binding_replacement('participation_id', 44, pending: true)
  end

  def test_remote_reader_change_replaces_active_binding_with_empty_outbox
    assert_remote_binding_replacement('reader_id', 55, pending: false)
  end

  def test_remote_reader_change_replaces_active_binding_with_pending_delivery
    assert_remote_binding_replacement('reader_id', 55, pending: true)
  end

  def test_unchanged_binding_with_changed_display_metadata_still_rejects_duplicate
    old = create_link
    assert_raises(ActiveRecord::RecordInvalid) do
      create_link(remote: @remote.merge('name' => 'Renamed reader', 'email' => 'renamed@example.org'))
    end
    assert old.reload.active?
    assert_equal @remote.fetch('name'), old.remote_name
    assert_equal 'dest@example.org', old.email
    assert_equal 1, Bible270::ProgressSyncLink.count
  end

  def test_remote_binding_replacement_rolls_back_pause_if_new_link_is_invalid
    old = create_link
    add_checkoff
    queued = Bible270::ProgressSyncDelivery.sole
    before = queued.attributes
    assert_raises(ActiveRecord::RecordInvalid) do
      create_link(remote: @remote.merge('generation' => 1, 'name' => ''))
    end
    assert old.reload.active?
    assert_nil old.last_error
    assert_equal 1, Bible270::ProgressSyncLink.count
    assert_equal before, queued.reload.attributes
  end

  def test_explicit_link_can_replace_a_stale_link_before_a_worker_observes_it
    old = create_link
    delivery = Sync.capture(@membership, [[1, 'ot', 0]]).first
    @membership.update!(progress_sync_generation: @membership.progress_sync_generation + 1)
    replacement = create_link
    assert old.reload.paused?
    assert replacement.usable?
    refute_equal old.id, replacement.id
    assert_equal old.id, delivery.reload.progress_sync_link_id
    assert_equal @membership.progress_sync_generation, replacement.source_generation
  end

  def test_copy_existing_is_repeatable_add_only_and_does_not_change_dates
    add_checkoff
    link = create_link
    before = @reader.attributes.slice('started_on', 'updated_at')
    2.times do
      delivery = Sync.copy_existing!(link)
      assert_equal [[1, 'ot', 0]], delivery.readings
    end
    destination = Set.new([[2, 'ot', 0]])
    calls = []
    client = completion_client do |target, readings|
      refute ActiveRecord::Base.connection.transaction_open?
      assert_equal link.id, target.id
      calls << readings
      added = readings.count { |triple| destination.add?(triple) }
      { 'added' => added, 'existing' => readings.length - added }
    end
    with_client(client) { assert_equal 2, Sync.deliver_pending }
    assert_equal Set.new([[1, 'ot', 0], [2, 'ot', 0]]), destination
    assert_equal 2, calls.length
    assert_equal 1, Bible270::Checkoff.count
    assert_equal before, @reader.reload.attributes.slice('started_on', 'updated_at')
    assert_equal 0, link.reload.last_added
    assert_equal 1, link.last_existing
    assert link.last_synced_at
    assert_equal 'Synced', link.status
    assert_equal 2, link.delivered_count
    assert_equal 0, link.pending_count
  end

  def test_copy_only_current_active_membership_and_empty_snapshot_returns_nil
    link = create_link
    assert_nil Sync.copy_existing!(link)
    add_checkoff
    @membership.update!(active: false)
    assert_raises(Sync::Conflict) { Sync.copy_existing!(link) }
    assert link.reload.paused?
    assert_equal 1, Bible270::ProgressSyncDelivery.count
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

  def test_multiple_destination_links_receive_separate_outbox_entries
    create_link
    Bible270.config.progress_sync_destinations['other'] = { url: 'https://other.example/bible', secret: 't' * 32 }
    create_link(destination: 'other')
    deliveries = Sync.capture(@membership, [[1, 'ot', 0]])
    assert_equal 2, deliveries.length
    assert_equal %w[church other], deliveries.map { |delivery| delivery.progress_sync_link.destination }.sort
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

  def test_invalid_destination_configuration_and_remote_identifiers_are_rejected
    assert_raises(Sync::Conflict) { create_link(remote: @remote.merge('reader_id' => '22oops')) }
    assert_raises(Sync::Conflict) { create_link(remote: @remote.merge('generation' => -1)) }
    assert_raises(Sync::Conflict) { create_link(remote: @remote.merge('email' => '')) }
    Bible270.config.progress_sync_destinations['church'][:url] = 'http://church.example/bible'
    assert_raises(Sync::ConfigurationError) { create_link }
    Bible270.config.progress_sync_destinations['church'][:url] = 'https://church.example/bible'
    Bible270.config.progress_sync_destinations['church'][:secret] = 'short'
    assert_raises(Sync::ConfigurationError) { create_link }
    assert_empty Bible270::ProgressSyncLink.all
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

  def test_no_http_entrypoint_runs_inside_an_outer_transaction
    create_link
    Sync.capture(@membership, [[1, 'ot', 0]])
    with_client(Object.new) do
      ActiveRecord::Base.transaction do
        assert_raises(Sync::ConfigurationError) { Sync.deliver_pending }
        assert_raises(Sync::ConfigurationError) { Sync.lookup(destination: 'church', email: 'dest@example.org') }
      end
    end
    assert_equal 0, Bible270::ProgressSyncDelivery.first.attempts
  end

private

  def assert_remote_binding_replacement(key, value, pending:)
    old = create_link
    original_binding = old.attributes.slice('remote_reader_id', 'remote_participation_id', 'remote_generation')
    add_checkoff if pending
    queued = old.deliveries.first
    queued_attributes = queued&.attributes
    remote = @remote.merge(key => value)
    assert old.usable?, 'the old link is still locally valid before the destination change is observed'
    assert_nil old.last_synced_at

    replacement = nil
    with_client(Object.new) { replacement = create_link(remote: remote) }
    assert old.reload.paused?
    assert replacement.usable?
    refute_equal old.id, replacement.id
    assert_equal original_binding, old.attributes.slice(*original_binding.keys)
    assert_equal @membership.progress_sync_generation, replacement.source_generation
    assert_equal remote.fetch('reader_id'), replacement.remote_reader_id
    assert_equal remote.fetch('participation_id'), replacement.remote_participation_id
    assert_equal remote.fetch('generation'), replacement.remote_generation
    assert_equal [replacement.id], Bible270::ProgressSyncLink.active.pluck(:id)
    assert_equal 2, Bible270::ProgressSyncLink.count
    with_client(Object.new) { assert_equal 0, Sync.deliver_pending }

    if pending
      assert_equal queued_attributes, queued.reload.attributes
      assert_equal old.id, queued.progress_sync_link_id
      add_checkoff(day: 2)
      calls = []
      client = completion_client do |link, readings|
        refute ActiveRecord::Base.connection.transaction_open?
        calls << [link.id, readings]
        { 'added' => 1, 'existing' => 0 }
      end
      with_client(client) { assert_equal 1, Sync.deliver_pending }
      assert_equal [[replacement.id, [[2, 'ot', 0]]]], calls
      assert_equal queued_attributes, queued.reload.attributes
    else
      assert_empty Bible270::ProgressSyncDelivery.all
    end
    assert_raises(ActiveRecord::RecordInvalid) { create_link(remote: remote) }
  end

  def create_link(**overrides)
    Sync.link!(reader: @reader, destination: 'church', remote: @remote,
               expected_participation_id: @membership.id, **overrides)
  end

  def add_checkoff(day: 1)
    Bible270::Checkoff.create!(reader: @reader, participation: @membership, day: day, track: 'ot', part: 0)
  end

  def completion_client(&block)
    Object.new.tap { |client| client.define_singleton_method(:complete) { |*args| block.call(*args) } }
  end

  def with_client(client, &)
    Sync::Client.stub(:new, client, &)
  end
end
