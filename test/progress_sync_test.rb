# frozen_string_literal: true

require_relative 'support/progress_sync_test_case'

class ProgressSyncTest < Bible270ProgressSyncTestCase
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

  def test_multiple_destination_links_receive_separate_outbox_entries
    create_link
    Bible270.config.progress_sync_destinations['other'] = { url: 'https://other.example/bible', secret: 't' * 32 }
    create_link(destination: 'other')
    deliveries = Sync.capture(@membership, [[1, 'ot', 0]])
    assert_equal 2, deliveries.length
    assert_equal %w[church other], deliveries.map { |delivery| delivery.progress_sync_link.destination }.sort
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
end
