# frozen_string_literal: true

require 'test_helper'
require 'bible270/scripture_frames'

class ScriptureFrameRotationTest < Minitest::Test
  ROTATION = Bible270::ScriptureFrameRotation
  SESSION_KEY = ROTATION::SESSION_KEY

  def frames(count)
    Array.new(count) { |index| Bible270::ScriptureFrames::Entry.new(id: "default:frame-#{index}") }
  end

  def select(pool, session, **)
    ROTATION.select(pool, session: session, **)&.id
  end

  def copy(value)
    JSON.parse(JSON.generate(value))
  end

  def test_every_cycle_covers_every_id_without_adjacent_repeats
    [2, 3, 20, 101].each do |size|
      pool = frames(size)
      session = {}
      previous = nil
      8.times do
        selected = Array.new(size) do
          id = select(pool, session, exclude: previous)
          refute_equal previous, id
          previous = id
        end
        assert_equal pool.map(&:id).sort, selected.sort
      end
    end
  end

  def test_changing_client_exclusions_never_sacrifices_coverage_or_creates_adjacent_repeats
    random = Random.new(270)
    (2..8).each do |size|
      pool = frames(size)
      ids = pool.map(&:id)
      session = {}
      previous = nil
      12.times do
        selected = Array.new(size) do
          exclude = (ids + [nil, 'unknown']).sample(random: random)
          id = select(pool, session, exclude: exclude)
          refute_equal previous, id
          previous = id
        end
        assert_equal ids.sort, selected.sort
      end
    end
  end

  def test_catalog_order_does_not_change_an_existing_rotation
    pool = frames(20)
    session = {}
    select(pool, session)
    reversed_session = copy(session)

    SecureRandom.stub(:hex, '0000000000000001') do
      50.times do
        assert_equal select(pool, session), select(pool.reverse, reversed_session)
        assert_equal session, reversed_session
      end
    end
  end

  def test_fresh_visitors_receive_independent_seeds_and_do_not_mutate_shared_entries
    pool = frames(20).each(&:freeze).freeze
    sessions = [{}, {}]
    seeds = %w[0000000000000001 0000000000000002]
    SecureRandom.stub(:hex, ->(length) {
      assert_equal 8, length
      seeds.shift
    }) do
      sessions.each { |session| select(pool, session) }
    end

    refute_equal sessions.first[SESSION_KEY]['state']['seed'], sessions.last[SESSION_KEY]['state']['seed']
    refute_equal sessions.first, sessions.last
    assert pool.all?(&:frozen?)
  end

  def test_exclusion_defers_an_unseen_frame_instead_of_discarding_it
    pool = frames(5)
    session = {}
    SecureRandom.stub(:hex, '0000000000000001') { select(pool, session) }
    state = session[SESSION_KEY]['state']
    state.merge!('cursor' => 0, 'last' => nil, 'deferred' => [])
    order = pool.sort_by(&:id).shuffle(random: Random.new(1)).map(&:id)
    blocked = order.first

    assert_equal order[1], select(pool, session, exclude: blocked)
    assert_equal [0], session[SESSION_KEY]['state']['deferred']
    assert_equal blocked, select(pool, session), 'changing exclude must make the deferred candidate available'
    selected = [order[1], blocked] + Array.new(3) { select(pool, session, exclude: order.last) }
    assert_equal pool.map(&:id).sort, selected.sort
    assert_equal order.last, selected.last, 'the last unseen candidate wins over exclude'
  end

  def test_two_different_blockers_can_be_deferred_and_recovered_without_repeats
    pool = frames(3)
    session = {}
    SecureRandom.stub(:hex, '0000000000000001') { select(pool, session) }
    order = pool.sort_by(&:id).shuffle(random: Random.new(1)).map(&:id)
    state = session[SESSION_KEY]['state']
    state.merge!('cursor' => 0, 'last' => Digest::SHA256.hexdigest(order[0]), 'deferred' => [])

    assert_equal order[2], select(pool, session, exclude: order[1])
    assert_equal [0, 1], session[SESSION_KEY]['state']['deferred']
    assert_equal order[1], select(pool, session, exclude: order[0])
    assert_equal order[0], select(pool, session, exclude: order[0])
    assert_empty session[SESSION_KEY]['state']['deferred']
  end

  def test_two_frame_conflicts_prefer_coverage_and_the_server_last_over_exclude
    pool = frames(2)
    session = {}
    previous = select(pool, session)
    20.times do
      other = (pool.map(&:id) - [previous]).first
      selected = select(pool, session, exclude: other)
      assert_equal other, selected
      previous = selected
    end
  end

  def test_unseen_candidates_take_priority_over_restarting_for_exclusion
    pool = frames(3)
    session = {}
    first = select(pool, session)
    second = select(pool, session)
    unseen = (pool.map(&:id) - [first, second]).first

    assert_equal unseen, select(pool, session, exclude: unseen)
    refute_equal unseen, select(pool, session, exclude: first)
  end

  def test_large_catalog_uses_bounded_state_without_ids_or_catalog_text
    pool = frames(10_000)
    session = {}
    previous = nil
    15.times do
      previous = select(pool, session, exclude: previous)
      serialized = JSON.generate(session)
      assert_operator serialized.bytesize, :<, 512
      refute_includes serialized, 'default:frame-'
      assert_operator session[SESSION_KEY]['state']['deferred'].length, :<=, 2
    end
    assert_equal [SESSION_KEY], session.keys
  end

  def test_empty_and_sole_frame_pools
    session = {}
    assert_nil select([], session)
    pool = frames(1)
    5.times { assert_equal pool.first.id, select(pool, session, exclude: pool.first.id) }
    assert_nil select([], session)
    assert_operator JSON.generate(session).bytesize, :<, 512
  end

  def test_catalog_changes_restart_but_preserve_the_last_frame_guard
    pool = frames(5)
    session = {}
    last = select(pool, session)
    previous_catalog = session[SESSION_KEY]['state']['catalog']
    expanded = pool + [Bible270::ScriptureFrames::Entry.new(id: 'custom:new')]

    first = select(expanded, session)
    refute_equal last, first
    refute_equal previous_catalog, session[SESSION_KEY]['state']['catalog']
    selected = [first] + Array.new(5) { select(expanded, session) }
    assert_equal expanded.map(&:id).sort, selected.sort
  end

  def test_corrupt_session_envelopes_reset_safely
    [nil, [], 'bad', 4, { 'identity' => 'visitor', 'state' => [] },
     { 'identity' => 'someone-else', 'state' => {} }].each do |entry|
      session = { SESSION_KEY => entry }
      assert_includes frames(3).map(&:id), select(frames(3), session)
      assert_equal 'visitor', session[SESSION_KEY]['identity']
    end
  end

  def test_corrupt_rotation_state_and_unbounded_seeds_reset_safely
    pool = frames(5)
    session = {}
    select(pool, session)
    valid = copy(session[SESSION_KEY]['state'])
    corruptions = [nil, [], 'bad', { :seed => 'bad' },
                   valid.merge('seed' => 'f' * 100_000), valid.merge('seed' => -1),
                   valid.merge('seed' => 'g' * 16), valid.merge('seed' => []),
                   valid.merge('cursor' => -1), valid.merge('cursor' => 6),
                   valid.merge('cursor' => '1'), valid.merge('deferred' => [0, 0]),
                   valid.merge('deferred' => [0, 1, 2]), valid.merge('deferred' => [-1]),
                   valid.merge('deferred' => ['0']), valid.merge('deferred' => [5]),
                   valid.merge('deferred' => {}), valid.merge('last' => []),
                   valid.merge('version' => 999), valid.merge(:extra => 'bad'),
                   valid.merge('catalog' => 'outdated')]

    corruptions.each do |state|
      session[SESSION_KEY] = { 'identity' => 'visitor', 'state' => state }
      assert_includes pool.map(&:id), select(pool, session)
      fresh = session[SESSION_KEY]['state']
      assert_match(%r{\A[0-9a-f]{16}\z}, fresh['seed'])
      assert_operator fresh['cursor'], :<=, 3
      assert_operator JSON.generate(session).bytesize, :<, 512
    end
  end

  def test_non_string_exclusions_are_ignored
    pool = frames(5)
    session = {}
    select(pool, session)
    [[], {}, 0, true].each do |exclude|
      baseline = copy(session)
      assert_equal select(pool, baseline), select(pool, session, exclude: exclude)
    end
  end

  if RAILS_LOADED
    def setup
      clear_engine_tables!
    end

    def new_reader(uid = 'rotation@example.org')
      Bible270::Reader.create!(provider: 'email', uid: uid, email: uid, display_name: 'Rotation Reader')
    end

    def test_reader_rotation_persists_across_instances_and_sessions_without_profile_or_run_changes
      reader = new_reader
      reader.mark_day_complete!(1)
      attributes = reader.reload.attributes.except('scripture_frame_rotation')
      participations = Bible270::Participation.all.map(&:attributes)
      runs = Bible270::PlanRun.all.map(&:attributes)
      checkoffs = Bible270::Checkoff.all.map(&:attributes)
      pool = frames(20)
      assert_equal({}, reader.scripture_frame_rotation)
      reader.display_name = 'Unsaved profile edit'

      ids = Array.new(20) { select(pool, {}, reader: Bible270::Reader.find(reader.id)) }
      # An unsaved request-reader must not be reloaded, saved, or locked.
      select(pool, {}, reader: reader)
      assert_equal 'Unsaved profile edit', reader.display_name
      assert reader.changed?
      assert_equal pool.map(&:id).sort, ids.sort
      assert_equal attributes, reader.reload.attributes.except('scripture_frame_rotation')
      assert_equal participations, Bible270::Participation.all.map(&:attributes)
      assert_equal runs, Bible270::PlanRun.all.map(&:attributes)
      assert_equal checkoffs, Bible270::Checkoff.all.map(&:attributes)
    end

    def test_empty_pool_leaves_an_unstarted_reader_state_at_its_migration_default
      reader = new_reader
      assert_nil select([], {}, reader: reader)
      assert_equal({}, reader.reload.scripture_frame_rotation)
    end

    def test_corrupt_persisted_reader_state_resets_without_using_session_state
      reader = new_reader
      reader.update_column(:scripture_frame_rotation, ['corrupt'])
      pool = frames(4)
      session = {}
      ids = Array.new(4) { select(pool, session, reader: reader) }
      assert_equal pool.map(&:id).sort, ids.sort
      assert_empty session
      assert_equal 4, reader.reload.scripture_frame_rotation['cursor']
    end

    def test_reader_selection_locks_a_fresh_record_and_persists_inside_that_lock
      reader = new_reader
      locked = Bible270::Reader.find(reader.id)
      find = ->(id) {
        assert_equal reader.id, id
        locked
      }
      in_lock = false
      original_update = locked.method(:update_column)
      update = ->(column, state) {
        assert in_lock
        original_update.call(column, state)
      }
      lock = ->(&block) {
        in_lock = true
        begin
          block.call
        ensure
          in_lock = false
        end
      }

      Bible270::Reader.stub(:find, find) do
        locked.stub(:with_lock, lock) do
          locked.stub(:update_column, update) { select(frames(3), {}, reader: reader) }
        end
      end
      assert_equal 1, reader.reload.scripture_frame_rotation['cursor']
    end

    def test_reader_state_is_authoritative_over_stale_instances_and_different_session_state
      reader = new_reader
      stale = Bible270::Reader.find(reader.id)
      pool = frames(10)
      session = {}
      select(pool, session)
      visitor_snapshot = copy(session)
      selected = Array.new(10) do |index|
        select(pool, session, reader: index.even? ? reader : stale)
      end

      assert_equal pool.map(&:id).sort, selected.sort
      assert_equal visitor_snapshot, session, 'signed-in rotation belongs in the reader row, not the cookie'
    end

    def test_different_readers_have_independent_rotations
      readers = [new_reader, new_reader('another@example.org')]
      seeds = %w[0000000000000001 0000000000000002]
      SecureRandom.stub(:hex, ->(_) { seeds.shift }) do
        readers.each { |reader| select(frames(20), {}, reader: reader) }
      end

      refute_equal readers.first.reload.scripture_frame_rotation['seed'], readers.last.reload.scripture_frame_rotation['seed']
    end

    def test_pending_migration_uses_one_identity_scoped_session_entry
      readers = [new_reader, new_reader('another@example.org')]
      pool = frames(5)
      session = {}
      columns = Bible270::Reader.column_names - ['scripture_frame_rotation']
      Bible270::Reader.stub(:column_names, columns) do
        ids = Array.new(5) { select(pool, session, reader: readers.first) }
        assert_equal pool.map(&:id).sort, ids.sort
        first_seed = session[SESSION_KEY]['state']['seed']
        select(pool, session, reader: readers.last)
        assert_equal "reader:#{readers.last.id}", session[SESSION_KEY]['identity']
        refute_equal first_seed, session[SESSION_KEY]['state']['seed']
        select(pool, session)
        assert_equal 'visitor', session[SESSION_KEY]['identity']
      end
      assert_equal [SESSION_KEY], session.keys
      readers.each { |reader| assert_equal({}, reader.reload.scripture_frame_rotation) }
    end

    def test_reader_rotation_survives_a_new_run
      reader = new_reader
      pool = frames(5)
      first = select(pool, {}, reader: reader)
      snapshot = copy(reader.reload.scripture_frame_rotation)
      reader.restart_on!(day: 1, on: Bible270.today)
      assert_equal snapshot, reader.reload.scripture_frame_rotation
      ids = [first] + Array.new(4) { select(pool, {}, reader: reader) }
      assert_equal pool.map(&:id).sort, ids.sort
    end
  end
end
