# frozen_string_literal: true

require 'test_helper'
require 'bible270/reader_consistency'
require 'bible270/reader_progress_report'

if RAILS_LOADED
  class PlanRunRevertsTest < Minitest::Test
    def setup
      needs_rails!
      clear_engine_tables!
      @previous = %i[start_date allow_reader_start_date enrollment_open mention_notifications time_zone admin_emails admin_resolver].to_h do |key|
        [key, Bible270.config.public_send(key)]
      end
      Bible270.config.start_date = Bible270.today - 9
      Bible270.config.allow_reader_start_date = true
      Bible270.config.enrollment_open = true
      Bible270.config.mention_notifications = false
      Bible270.config.time_zone = 'UTC'
      Bible270.config.admin_emails = []
      Bible270.config.admin_resolver = nil
    end

    def teardown
      @previous&.each { |key, value| Bible270.config.public_send("#{key}=", value) }
    end

    def test_restart_persists_a_snapshot_and_only_the_current_new_run_is_revertible
      active = reader('Active')
      alumni = reader('Alumni')
      alumni.archive!
      previous = Bible270::PlanRun.current
      refute previous.revertible?

      fresh = restart_run
      snapshot = fresh.reload.restart_snapshot

      assert_kind_of Hash, snapshot
      assert_equal previous.id, snapshot.fetch('previous_run_id')
      assert_equal [active.participation.id], snapshot.fetch('active_participation_ids')
      assert fresh.revertible?
      refute previous.reload.revertible?
      revert_run
      refute fresh.reload.revertible?
      assert fresh.reverted_at
      refute previous.reload.revertible?
    end

    def test_revert_restores_exactly_prior_active_members_and_preserves_all_content_and_roles
      active = reader('Active', started_on: Bible270.today - 3, admin: true)
      alumni = reader('Same-day alumni', started_on: Bible270.today - 5)
      active.mark_day_complete!(1)
      alumni.mark_day_complete!(1)
      alumni.archive!
      previous = Bible270::PlanRun.current
      active_membership = active.participation
      alumni_membership = alumni.participation
      alumni_snapshot = alumni_membership.attributes
      reflection = active.comments.create!(day: 1, body: 'Keep this reflection')
      like = reflection.likes.create!(reader: alumni)
      fresh = restart_run
      active.reload.activate!
      active.mark_day_complete!(2)
      active.archive!
      alumni.reload.activate!
      alumni.set_start_date!(Bible270.today + 3)
      alumni.mark_day_complete!(3)
      newcomer = reader('Newer-only', started_on: Bible270.today + 2)
      newcomer.mark_day_complete!(2)
      newer_memberships = fresh.participations.order(:id).pluck(:id)
      content = [Bible270::Checkoff, Bible270::Comment, Bible270::Like].map { |model| model.order(:id).map(&:attributes) }
      roles = Bible270::Reader.order(:id).pluck(:id, :admin)

      revert_run

      assert_equal previous, Bible270::PlanRun.current
      assert previous.reload.current?
      assert_nil previous.archived_at
      assert_nil fresh.reload.current
      assert fresh.archived_at
      assert fresh.reverted_at
      assert_equal 2, Bible270::PlanRun.count
      assert_equal [active.id], Bible270::Reader.active.pluck(:id)
      assert_equal [alumni.id, newcomer.id].sort, Bible270::Reader.alumni.pluck(:id).sort
      assert_equal active_membership, active.reload_progress.participation
      assert active_membership.reload.active?
      assert_nil active_membership.archived_on
      assert_nil active_membership.frozen_start_date
      assert_equal alumni_membership, alumni.reload_progress.participation
      assert_equal alumni_snapshot, alumni_membership.reload.attributes
      assert_equal Bible270.today - 5, alumni.reload.started_on
      assert_equal newer_memberships, fresh.participations.order(:id).pluck(:id)
      assert fresh.participations.all?(&:alumni?)
      assert_equal fresh, newcomer.reload_progress.participation.plan_run
      assert_equal 1, newcomer.days_completed
      assert_equal Bible270.today + 2, newcomer.effective_start_date
      assert_equal roles, Bible270::Reader.order(:id).pluck(:id, :admin)
      refute alumni.reload.admin?
      assert_equal(content, [Bible270::Checkoff, Bible270::Comment, Bible270::Like].map { |model| model.order(:id).map(&:attributes) })
    ensure
      like&.destroy!
    end

    def test_revert_restores_original_alumni_status_even_for_admins_and_site_admins
      personal_date = Bible270.today - 5
      admin = reader('Alumni admin', admin: true, started_on: personal_date)
      site_admin = reader('Alumni site-admin', email: 'site-admin@example.org', started_on: personal_date)
      ordinary = reader('Ordinary alumni')
      original_memberships = [admin, site_admin].to_h do |participant|
        participant.mark_day_complete!(1)
        [participant.id, participant.archive!]
      end
      ordinary.archive!
      previous = Bible270::PlanRun.current
      fresh = restart_run
      new_admin = reader('New admin', admin: true, started_on: Bible270.today + 2)
      new_site_admin = reader('New site-admin', email: 'new-site-admin@example.org', started_on: Bible270.today + 3)
      Bible270.config.admin_emails = [site_admin.email, new_site_admin.email]
      newer_memberships = [new_admin, new_site_admin].to_h do |participant|
        participant.mark_day_complete!(2)
        [participant.id, participant.archive!]
      end
      checkoffs = Bible270::Checkoff.order(:id).map(&:attributes)

      revert_run

      assert_empty Bible270::Reader.active
      assert_equal [admin, site_admin, new_admin, new_site_admin, ordinary].map(&:id).sort, Bible270::Reader.alumni.order(:id).pluck(:id)
      [admin, site_admin].each do |participant|
        participant.reload
        assert participant.alumni?
        assert_equal original_memberships.fetch(participant.id), participant.participation
        assert_equal personal_date, participant.started_on
        assert_equal 1, participant.days_completed
        assert_equal Bible270.today, participant.participation.archived_on
        assert_equal personal_date, participant.participation.frozen_start_date
      end
      [new_admin, new_site_admin].each do |participant|
        participant.reload
        assert participant.alumni?
        assert_equal fresh.id, participant.participation.plan_run_id
        refute participant.participations.exists?(plan_run_id: previous.id)
        assert_equal 1, participant.days_completed
        history = newer_memberships.fetch(participant.id).reload
        assert history.alumni?
        assert_equal fresh.id, history.plan_run_id
        assert_equal 1, history.checkoffs.distinct.count(:day)
      end
      assert_equal checkoffs, Bible270::Checkoff.order(:id).map(&:attributes)
      assert admin.admin?
      assert new_admin.admin?
      refute site_admin.admin?
      refute new_site_admin.admin?
      assert Bible270.config.site_admin?(site_admin)
      assert Bible270.config.site_admin?(new_site_admin)
    end

    def test_restart_enrolls_resolver_site_admins_but_revert_restores_their_alumni_status
      personal_date = Bible270.today - 5
      site_admin = reader('Resolver site-admin', started_on: personal_date)
      site_admin.mark_day_complete!(1)
      ordinary = reader('Ordinary alumni')
      [site_admin, ordinary].each(&:archive!)
      Bible270.config.admin_resolver = ->(participant) { participant.id == site_admin.id }
      fresh = restart_run
      refute site_admin.reload.alumni?
      assert_equal fresh.id, site_admin.participation.plan_run_id
      assert_nil site_admin.started_on
      assert_equal 0, site_admin.days_completed

      revert_run

      assert_empty Bible270::Reader.active
      assert site_admin.reload.alumni?
      refute site_admin.admin?
      assert Bible270.config.site_admin?(site_admin)
      assert_equal personal_date, site_admin.started_on
      assert_equal 1, site_admin.reload_progress.days_completed
      assert ordinary.reload.alumni?
    end

    def test_failure_during_admin_enrollment_rolls_back_the_entire_restart
      admin = reader('First admin', admin: true)
      site_admin = reader('Failing site-admin')
      [admin, site_admin].each(&:archive!)
      fresh = restart_run
      before = database_snapshot
      observed_activation = false
      Bible270.config.admin_resolver = ->(participant) do
        if participant.id == site_admin.id
          observed_activation = Bible270::PlanRun.current.id != fresh.id && Bible270::Participation.active.exists?(reader_id: admin.id)
          raise 'simulated role lookup failure'
        end
        false
      end

      error = assert_raises(RuntimeError) { restart_run }

      assert_equal 'simulated role lookup failure', error.message
      assert observed_activation
      assert_equal before, database_snapshot
      assert_equal fresh, Bible270::PlanRun.current
    end

    def test_earlier_alumni_who_skipped_the_restored_run_choose_their_non_reverted_history
      personal_date = Bible270.today - 20
      early = reader('Early alumni', started_on: personal_date)
      early.mark_day_complete!(1)
      earliest = Bible270::PlanRun.current
      Bible270.stub(:today, Bible270.today - 10) { early.archive! }
      historical_membership = early.participation
      historical_snapshot = historical_membership.attributes
      restored = restart_run
      active = reader('Active in restored run')
      active_ids = Bible270::Reader.active.order(:id).pluck(:id)
      refute early.participations.exists?(plan_run: restored)
      fresh = restart_run
      early.reload.activate!
      early.set_start_date!(Bible270.today + 4)
      early.mark_day_complete!(2)
      early.mark_day_complete!(3)
      newer_membership = early.participation
      newer_checkoffs = newer_membership.checkoffs.order(:id).pluck(:id)

      revert_run

      assert_equal restored, Bible270::PlanRun.current
      assert_equal active_ids, Bible270::Reader.active.order(:id).pluck(:id)
      refute active.reload_progress.alumni?
      assert early.reload.alumni?
      assert_equal historical_membership, early.participation
      assert_equal earliest, early.participation.plan_run
      assert_equal historical_snapshot, historical_membership.reload.attributes
      assert_equal personal_date, early.started_on
      assert_equal personal_date, early.effective_start_date
      assert_equal 1, early.days_completed
      assert_equal historical_membership.id, Bible270::Participation.chosen.find_by!(reader_id: early.id).id
      refute early.participations.exists?(plan_run: restored)
      assert newer_membership.reload.alumni?
      assert_equal Bible270.today + 4, newer_membership.frozen_start_date
      assert_equal newer_checkoffs, newer_membership.checkoffs.order(:id).pluck(:id)
      assert fresh.reload.reverted_at
    end

    def test_revert_does_not_resurrect_a_reader_deleted_after_restart
      deleted = reader('Deleted after restart', started_on: Bible270.today - 3)
      deleted.mark_day_complete!(1)
      survivor = reader('Survivor')
      previous = Bible270::PlanRun.current
      restart_run
      deleted.reload.activate!
      deleted.mark_day_complete!(2)
      deleted.comments.create!(day: 2, body: 'Deleted with the reader')
      deleted_id = deleted.id
      deleted.destroy!

      revert_run

      assert_equal previous, Bible270::PlanRun.current
      assert_equal [survivor.id], Bible270::Reader.active.pluck(:id)
      assert_equal [survivor.id], Bible270::Reader.pluck(:id)
      refute Bible270::Reader.exists?(deleted_id)
      assert_empty Bible270::Participation.where(reader_id: deleted_id)
      assert_empty Bible270::Checkoff.where(reader_id: deleted_id)
      assert_empty Bible270::Comment.where(reader_id: deleted_id)
    end

    def test_revert_restores_personal_shared_configured_and_undated_calendars
      configured = Bible270.today - 9
      override = Bible270.today - 6
      personal = Bible270.today - 3
      [
        [configured, nil, personal, true, personal],
        [configured, override, nil, true, override],
        [configured, nil, nil, true, configured],
        [nil, nil, nil, true, nil],
        [configured, override, personal, false, override]
      ].each do |config_date, runtime_date, personal_date, allow_personal, effective_date|
        clear_engine_tables!
        Bible270.config.start_date = config_date
        Bible270.config.allow_reader_start_date = allow_personal
        Bible270::Setting.set_run_start_date!(runtime_date) if runtime_date
        participant = reader('Calendar', started_on: personal_date)
        membership = participant.participation
        original_settings = raw_settings
        restart_run
        participant.reload.activate!
        participant.set_start_date!(Bible270.today + 5)
        Bible270::Setting.set_run_start_date!(Bible270.today + 10)

        revert_run

        assert_equal original_settings, raw_settings
        assert_equal !!runtime_date, Bible270::Setting.run_start_date_overridden?
        assert_equal [personal_date, personal_date, effective_date],
                     [participant.reload.started_on, membership.reload.started_on, participant.reload_progress.effective_start_date]
        assert_equal membership, participant.participation
      end
    end

    def test_same_reader_instance_uses_restored_personal_dates_after_reloading_progress
      original_date = Bible270.today - 4
      newer_date = Bible270.today + 2
      participant = reader('Cached calendar', started_on: original_date)
      original_membership = participant.participation
      restart_run
      participant.reload.activate!
      participant.set_start_date!(newer_date)
      assert_equal newer_date, participant.effective_start_date

      revert_run

      assert_equal newer_date, participant.started_on
      assert_same participant, participant.reload_progress
      assert_equal original_membership, participant.participation
      assert_equal original_date, participant.effective_start_date
      participant.participation.reader = participant
      assert_equal original_date, participant.participation.effective_start_date
    end

    def test_revert_freezes_the_newer_shared_override_before_restoring_previous_settings
      original_date = Bible270.today - 8
      newer_date = Bible270.today + 6
      Bible270::Setting.set_run_start_date!(original_date)
      participant = reader('Shared calendar')
      fresh = restart_run
      participant.reload.activate!
      newer_membership = participant.participation
      Bible270::Setting.set_run_start_date!(newer_date)
      assert_equal newer_date, participant.effective_start_date

      revert_run

      assert_equal original_date, Bible270::Setting.run_start_date
      assert_equal original_date, participant.reload_progress.effective_start_date
      assert_equal newer_date, fresh.reload.start_date
      assert_equal newer_date, newer_membership.reload.frozen_start_date
      assert_equal newer_date, newer_membership.effective_start_date
      assert newer_membership.alumni?
    end

    def test_legacy_bulk_insert_rejects_a_membership_selected_before_revert_wins_the_run_lock
      participant = reader('Interleaved bulk writer')
      participant.mark_day_complete!(1)
      fresh = restart_run
      participant.reload.activate!
      participant.mark_day_complete!(2)
      checkoffs = Bible270::Checkoff.order(:id).map(&:attributes)
      interleaved = false
      subscriber = ->(_name, _start, _finish, _id, payload) do
        next if interleaved || !payload[:sql].match?(%r{SELECT.*FROM "bible270_participations".*NOT EXISTS}im)

        interleaved = true
        Bible270::PlanRun.revert!(expected_run_id: fresh.id)
        assert_equal fresh.restart_snapshot.fetch('previous_run_id'), Bible270::PlanRun.current.id
      end
      row = { reader_id: participant.id, day: 3, track: 'nt', part: 0, created_at: Time.current, updated_at: Time.current }

      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        assert_raises(Bible270::Participation::ArchivedProgress) { Bible270::Checkoff.insert_all([row]) }
      end

      assert interleaved
      assert_equal checkoffs, Bible270::Checkoff.order(:id).map(&:attributes)
    end

    def test_new_reader_retries_into_the_restored_run_when_the_selected_newer_run_was_reverted
      reader('Existing reader')
      previous = Bible270::PlanRun.current
      fresh = restart_run
      revert_run
      selections = 0
      select_run = -> do
        selections += 1
        selections == 1 ? fresh : previous
      end

      Bible270::PlanRun.stub(:current, select_run) do
        newcomer = Bible270::Reader.from_email('restored-enrollment@example.org')
        assert newcomer.persisted?
        assert_equal previous, newcomer.participation.plan_run
        assert newcomer.participation.active?
        assert_equal 1, newcomer.participations.count
        assert_equal 2, selections
      end

      assert_empty fresh.participations
      assert_equal 2, previous.participations.active.count
    end

    def test_revert_restores_raw_enrollment_settings_including_absence_and_explicit_open
      closed_at = '2026-01-02T03:04:05+00:00'
      [
        [true, {}, false],
        [false, {}, true],
        [false, { Bible270::Setting::ENROLLMENT_OPEN => 'true' }, false],
        [true, { Bible270::Setting::ENROLLMENT_CLOSED_AT => closed_at }, true],
        [false, { Bible270::Setting::ENROLLMENT_OPEN => 'false' }, true],
        [true, { Bible270::Setting::ENROLLMENT_OPEN => nil, Bible270::Setting::ENROLLMENT_CLOSED_AT => '' }, false]
      ].each do |configured_open, settings, closed|
        clear_engine_tables!
        Bible270.config.enrollment_open = configured_open
        settings.each { |key, value| Bible270::Setting.write(key, value) }
        original = raw_settings
        restart_run
        refute Bible270::Setting.enrollment_closed?
        Bible270::Setting.close_enrollment!

        revert_run

        assert_equal original, raw_settings
        assert_equal closed, Bible270::Setting.enrollment_closed?
      end
    end

    def test_chosen_progress_counts_activity_and_writes_follow_the_restored_run
      participant = reader('Returning', created_at: Time.current - 20.days)
      participant.mark_day_complete!(1)
      old_membership = participant.participation
      participant.checkoffs.update_all(created_at: Time.current - 2.days)
      old_activity = Bible270::Checkoff.recent_activity_by_reader([participant.id]).fetch(participant.id)
      old_consistency = Bible270::ReaderConsistency.new(readers: [participant]).for(participant)
      fresh = restart_run
      participant.reload.activate!
      participant.mark_day_complete!(2)
      participant.mark_day_complete!(3)
      stale_reader = Bible270::Reader.find(participant.id)
      newer_membership = stale_reader.participation
      newer_checkoffs = newer_membership.checkoffs.order(:id).map(&:attributes)

      revert_run

      participant.reload_progress
      assert_equal old_membership, participant.participation
      assert_equal [old_membership.id], Bible270::Participation.chosen.pluck(:id)
      assert_equal 1, participant.days_completed
      assert_equal 1, Bible270::Reader.completed_days_by_id.fetch(participant.id)
      assert_equal [participant.id], Bible270::Reader.completers_for(1).map(&:id)
      assert_empty Bible270::Reader.completers_for(2)
      assert_equal old_activity, Bible270::Checkoff.recent_activity_by_reader([participant.id]).fetch(participant.id)
      assert_equal old_consistency, Bible270::ReaderConsistency.new(readers: [participant]).for(participant)
      assert_equal 1, Bible270::ReaderProgressReport.new.rows.first.days_read
      assert_raises(Bible270::Participation::ArchivedProgress) { stale_reader.mark_day_complete!(4) }
      assert_raises(Bible270::Participation::ArchivedProgress) { stale_reader.clear_day!(2) }
      assert_raises(Bible270::Participation::ArchivedProgress) { stale_reader.set_start_date!(Bible270.today) }
      assert_raises(Bible270::Participation::ArchivedProgress) { newer_membership.reload.ensure_writable! }
      participant.mark_day_complete!(4)
      assert_equal [1, 4], old_membership.checkoffs.distinct.order(:day).pluck(:day)
      assert_equal newer_checkoffs, newer_membership.checkoffs.order(:id).map(&:attributes)
      assert fresh.reload.reverted_at
    end

    def test_settings_failure_rolls_back_runs_memberships_dates_and_settings_together
      participant = reader('Rollback', started_on: Bible270.today - 3)
      Bible270::Setting.set_run_start_date!(Bible270.today - 5)
      Bible270::Setting.close_enrollment!
      fresh = restart_run
      participant.reload.activate!
      participant.set_start_date!(Bible270.today + 2)
      participant.mark_day_complete!(1)
      before = database_snapshot

      Bible270::Setting.stub(:write, ->(*) { raise 'simulated revert failure' }) do
        error = assert_raises(RuntimeError) { revert_run }
        assert_equal 'simulated revert failure', error.message
      end

      assert_equal before, database_snapshot
      assert_equal fresh, Bible270::PlanRun.current
      assert fresh.reload.revertible?
      refute participant.reload_progress.alumni?
      revert_run
      assert_equal Bible270.today - 3, participant.reload.started_on
    end

    def test_revert_locks_sorted_runs_then_sorted_readers_before_writes_in_one_transaction
      participant = reader('Locked reader', started_on: Bible270.today - 3)
      reader('Earlier alumni').archive!
      previous = Bible270::PlanRun.current
      Bible270::Setting.set_run_start_date!(Bible270.today - 5)
      fresh = restart_run
      participant.reload.activate!
      reader('Newer-only reader')
      reader_ids = Bible270::Reader.order(:id).pluck(:id)
      connection = Bible270::PlanRun.connection
      writes = []
      transactions = []
      lock_order = []
      locking_reads = []
      capture_record_locks(Bible270::PlanRun, lock_order) do |run_locks|
        capture_record_locks(Bible270::Reader, lock_order) do |reader_locks|
          subscriber = ->(_name, _start, _finish, _id, payload) do
            sql = payload[:sql]
            if sql.match?(%r{\ASELECT.*ORDER BY "bible270_(?:plan_runs|readers)"\."id" ASC}i)
              locking_reads << sql[%r{FROM "(bible270_\w+)"}, 1]
            end
            next unless sql.match?(%r{\A(?:UPDATE|INSERT INTO|DELETE FROM) ["`]?bible270_(?:plan_runs|participations|readers|settings)}i)

            assert connection.transaction_open?
            assert_equal [Bible270::PlanRun, Bible270::Reader], lock_order
            assert_equal %w[bible270_plan_runs bible270_readers], locking_reads.uniq
            [run_locks, reader_locks].each do |locks|
              assert_equal 1, locks.size
              assert locks.first.lock_value
            end
            assert_equal [previous.id, fresh.id], run_locks.first.map(&:id)
            assert_equal reader_ids, reader_locks.first.map(&:id)
            writes << sql
            transactions << connection.current_transaction.object_id
          end
          ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') { revert_run }
          [run_locks, reader_locks].each do |locks|
            table = locks.first.klass.table_name
            assert_match(%r{ORDER BY "#{table}"\."id" ASC}, locks.first.to_sql)
          end
        end
      end

      %w[plan_runs participations readers settings].each do |table|
        assert(writes.any? { |sql| sql.include?("bible270_#{table}") })
      end
      assert_equal 1, transactions.uniq.size
      refute connection.transaction_open?
    end

    def test_legacy_missing_stale_and_repeated_reverts_do_not_change_state
      reader('Reader')
      previous = Bible270::PlanRun.current
      assert_raises(Bible270::PlanRun::CannotRevert) { revert_run }
      fresh = restart_run
      before = database_snapshot
      [nil, '', previous.id, fresh.id + 100].each do |id|
        assert_raises(Bible270::PlanRun::StaleRun) { Bible270::PlanRun.revert!(expected_run_id: id) }
        assert_equal before, database_snapshot
      end
      revert_run
      restored = database_snapshot
      assert_raises(Bible270::PlanRun::StaleRun) { Bible270::PlanRun.revert!(expected_run_id: fresh.id) }
      assert_raises(Bible270::PlanRun::CannotRevert) { revert_run }
      assert_equal restored, database_snapshot
      legacy = restart_run
      legacy.update!(restart_snapshot: nil)
      refute legacy.reload.revertible?
      before = database_snapshot
      assert_raises(Bible270::PlanRun::CannotRevert) { revert_run }
      assert_equal before, database_snapshot
    end

    def test_multiple_restart_revert_lineage_uses_the_restored_predecessor_and_latest_valid_history
      participant = reader('Original')
      original = Bible270::PlanRun.current
      first = restart_run
      newer_only = reader('Newer only')
      newer_only.mark_day_complete!(1)
      first_membership = newer_only.participation
      revert_run
      assert_equal first_membership, newer_only.reload_progress.participation
      assert newer_only.alumni?
      second = restart_run
      assert_equal original.id, second.restart_snapshot.fetch('previous_run_id')
      newer_only.reload.activate!
      newer_only.mark_day_complete!(2)
      second_membership = newer_only.participation
      revert_run
      assert_equal second_membership, newer_only.reload_progress.participation
      assert_equal 1, newer_only.days_completed
      assert newer_only.alumni?
      assert_equal participant.participations.find_by!(plan_run: original), participant.reload_progress.participation

      third = restart_run
      newer_only.reload.activate!
      valid_membership = newer_only.participation
      fourth = restart_run
      newer_only.reload.activate!
      fourth_membership = newer_only.participation
      revert_run
      assert_equal third, Bible270::PlanRun.current
      assert_equal valid_membership, newer_only.reload_progress.participation
      refute newer_only.alumni?
      assert third.reload.revertible?
      revert_run
      assert_equal original, Bible270::PlanRun.current
      assert_equal fourth_membership, newer_only.reload_progress.participation
      assert newer_only.alumni?
      assert([first, second, third, fourth].all? { |run| run.reload.reverted_at })
      assert_equal 5, Bible270::PlanRun.count
    end

  private

    def reader(name, **attributes)
      Bible270::Reader.create!(display_name: name, **attributes)
    end

    def restart_run
      Bible270::PlanRun.restart!(start_date: Bible270.today + 1, expected_run_id: Bible270::PlanRun.current.id)
    end

    def revert_run
      Bible270::PlanRun.revert!(expected_run_id: Bible270::PlanRun.current.id)
    end

    # SQLite omits FOR UPDATE from SQL, so observe the real relation's lock flag
    # while retaining its database reads and the production transaction boundary.
    def capture_record_locks(model, lock_order)
      locks = []
      original_where = model.method(:where)
      tracked_where = ->(*arguments) do
        relation = original_where.call(*arguments)
        original_order = relation.method(:order).unbind
        relation.define_singleton_method(:order) do |*columns|
          ordered = original_order.bind_call(self, *columns)
          original_lock = ordered.method(:lock).unbind
          ordered.define_singleton_method(:lock) do |*options|
            original_lock.bind_call(self, *options).tap do |locked|
              locks << locked
              lock_order << model
            end
          end
          ordered
        end
        relation
      end
      model.stub(:where, tracked_where) { yield locks }
    end

    def raw_settings
      Bible270::Setting.order(:key).pluck(:key, :value)
    end

    def database_snapshot
      [Bible270::PlanRun, Bible270::Participation, Bible270::Reader, Bible270::Checkoff, Bible270::Setting].map do |model|
        model.order(:id).map(&:attributes)
      end
    end
  end
end
