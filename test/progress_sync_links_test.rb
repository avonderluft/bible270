# frozen_string_literal: true

require_relative 'support/progress_sync_test_case'

class ProgressSyncLinksTest < Bible270ProgressSyncTestCase
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
end
