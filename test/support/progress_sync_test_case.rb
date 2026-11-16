# frozen_string_literal: true

require 'test_helper'
require 'bible270/progress_sync'

class Bible270ProgressSyncTestCase < Minitest::Test
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
