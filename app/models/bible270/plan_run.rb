# frozen_string_literal: true

module Bible270
  class PlanRun < ApplicationRecord
    self.table_name = 'bible270_plan_runs'

    class InvalidStartDate < ArgumentError; end
    class StaleRun < StandardError; end
    class CannotRevert < StandardError; end
    class Plus95Unavailable < StandardError; end

    RESTART_SETTING_KEYS = [Setting::RUN_START_DATE, Setting::ENROLLMENT_OPEN, Setting::ENROLLMENT_CLOSED_AT].freeze

    has_many :participations, class_name: 'Bible270::Participation', inverse_of: :plan_run

    # The unique current marker also makes first enrollment safe on an empty DB.
    def self.current
      find_by(current: true) || create_or_find_by!(current: true)
    end

    def plus95_available? = has_attribute?(:plus95_enabled)

    def plus95_enabled? = plus95_available? && self[:plus95_enabled]

    def plan_days = plus95_enabled? ? Plan::EXTENDED_DAYS : Plan::DAYS

    # Use the same run lock as progress writes and run transitions. Only the
    # schedule changes; extension check-offs and reflections are kept as-is.
    def self.update_plus95!(enabled:, expected_run_id:)
      run = current
      run.with_lock do
        unless run.current? && run.id.to_s == expected_run_id.to_s
          raise StaleRun, 'The current run changed; reload before changing +95'
        end

        raise Plus95Unavailable unless run.plus95_available?

        run.update!(plus95_enabled: enabled)
      end
    end

    # expected_run_id is mandatory optimistic concurrency protection for the form.
    # All membership transitions lock the run first, so enrollment cannot land in
    # the old run halfway through this transaction.
    def self.restart!(start_date:, expected_run_id:, plus95_enabled: false)
      date = Plan.to_date(start_date)
      raise InvalidStartDate, 'start_date must be a valid date' unless date

      old_run = current
      transaction do
        old_run.lock!
        unless old_run.current? && old_run.id.to_s == expected_run_id.to_s
          raise StaleRun, 'The current run changed; reload before restarting'
        end

        raise Plus95Unavailable if plus95_enabled && !old_run.plus95_available?

        # Membership changes and admin role changes lock readers before their
        # participations. Hold those locks while archiving and enrolling admins.
        Reader.order(:id).lock.load
        snapshot = {
          'previous_run_id' => old_run.id,
          'active_participation_ids' => old_run.participations.where(active: true).order(:id).pluck(:id),
          'reader_start_dates' => Reader.order(:id).pluck(:id, :started_on).to_h.transform_values { |value| value&.iso8601 },
          'settings' => Setting.where(key: RESTART_SETTING_KEYS).pluck(:key, :value).to_h
        }
        old_run.archive_current_memberships!
        attributes = { current: true, start_date: date, restart_snapshot: snapshot }
        attributes[:plus95_enabled] = plus95_enabled if old_run.plus95_available?
        new_run = create!(attributes)
        Setting.set_run_start_date!(date)
        Setting.open_enrollment!
        activate_admins!
        new_run
      end
    end

    # Retain the abandoned run as read-only history rather than deleting work
    # completed since the restart. Lock both runs in the same order as bulk writes.
    def self.revert!(expected_run_id:)
      run = find_by(current: true)
      unless run && run.id.to_s == expected_run_id.to_s
        raise StaleRun, 'The current run changed; reload before reverting'
      end

      previous_id = run.restart_snapshot&.fetch('previous_run_id', nil)
      transaction do
        runs = where(id: [previous_id, run.id]).order(:id).lock.index_by(&:id)
        run = runs.fetch(run.id)
        unless run.current? && run.id.to_s == expected_run_id.to_s
          raise StaleRun, 'The current run changed; reload before reverting'
        end

        previous = runs[previous_id]
        unless run.revertible? && previous && !previous.current? && !previous.reverted_at
          raise CannotRevert, 'No saved restart is available to revert'
        end

        snapshot = run.restart_snapshot
        # Deletion and profile changes lock the reader before membership rows.
        # Match that order to avoid deadlocks while restoring personal dates.
        Reader.where(id: snapshot.fetch('reader_start_dates').keys)
          .or(Reader.where(id: run.participations.select(:reader_id))).order(:id).lock.load
        run.archive_current_memberships!
        run.update!(reverted_at: Time.current)
        previous.update!(current: true, archived_at: nil)
        previous.participations.where(id: snapshot.fetch('active_participation_ids')).update_all(
          active: true, archived_on: nil, frozen_start_date: nil, updated_at: Time.current
        )
        # Bypass schedule callbacks: these are restored snapshots, not edits to
        # whichever membership was selected before the transition.
        snapshot.fetch('reader_start_dates').group_by { |_id, date| date }.each do |date, readers|
          Reader.where(id: readers.map(&:first)).update_all(started_on: date)
        end
        settings = snapshot.fetch('settings')
        RESTART_SETTING_KEYS.each do |key|
          settings.key?(key) ? Setting.write(key, settings.fetch(key)) : Setting.delete_key(key)
        end
        previous
      end
    end

    def self.activate_admins!
      Reader.preload(participation: :plan_run).find_each do |reader|
        reader.activate! if Bible270.config.admin?(reader) && reader.alumni?
      end
    end
    private_class_method :activate_admins!

    def revertible?
      current? && !reverted_at && restart_snapshot.is_a?(Hash) &&
        self.class.where(id: restart_snapshot['previous_run_id'], current: nil, reverted_at: nil).exists?
    end

    def archive_current_memberships!
      shared_date = Setting.run_start_date
      participations.where(active: true).includes(:reader).find_each do |membership|
        membership.archive!(shared_start_date: shared_date)
      end
      update!(current: nil, start_date: shared_date, archived_at: Time.current)
    end

    def effective_start_date
      current? ? Setting.run_start_date : start_date
    end
  end
end
