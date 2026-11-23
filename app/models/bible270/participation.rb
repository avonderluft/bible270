# frozen_string_literal: true

module Bible270
  class Participation < ApplicationRecord
    self.table_name = 'bible270_participations'

    class ArchivedProgress < StandardError; end
    class InvalidPlanLength < ArgumentError; end

    PLUS95_CHOICES = { 'default' => nil, '0' => false, '1' => true }.freeze

    belongs_to :reader, class_name: 'Bible270::Reader', inverse_of: :participations
    belongs_to :plan_run, class_name: 'Bible270::PlanRun', inverse_of: :participations
    has_many :checkoffs, class_name: 'Bible270::Checkoff', dependent: :destroy, inverse_of: :participation

    before_update :invalidate_progress_sync_generation

    validates :reader_id, uniqueness: { scope: :plan_run_id }
    validates :joined_at, presence: true

    scope :active, -> { joins(:plan_run).where(active: true, bible270_plan_runs: { current: true }) }
    # Prefer the latest non-reverted membership, so undoing a restart restores
    # both current readers and earlier alumni. Readers who joined only reverted
    # runs can still view their latest archived progress. Keep this preloadable.
    scope :chosen, -> {
      joins(:plan_run).where(<<~SQL.squish)
        NOT EXISTS (
          SELECT 1 FROM bible270_participations newer
          INNER JOIN bible270_plan_runs newer_run ON newer_run.id = newer.plan_run_id
          WHERE newer.reader_id = bible270_participations.reader_id
            AND (
              (newer_run.reverted_at IS NULL AND bible270_plan_runs.reverted_at IS NOT NULL)
              OR (
                newer.plan_run_id > bible270_participations.plan_run_id
                AND (newer_run.reverted_at IS NULL OR bible270_plan_runs.reverted_at IS NOT NULL)
              )
            )
        )
      SQL
    }

    def self.with_plus95
      inherited = if PlanRun.column_names.include?('plus95_enabled')
                    where(plan_run_id: PlanRun.where(plus95_enabled: true).select(:id))
                  else
                    none
                  end
      return inherited unless column_names.include?('plus95_override')

      where(plus95_override: true).or(inherited.where(plus95_override: nil))
    end

    def plus95_override_available? = has_attribute?(:plus95_override)

    def plan_days
      override = self[:plus95_override] if plus95_override_available?
      return plan_run.plan_days if override.nil?

      override ? Plan::EXTENDED_DAYS : Plan::DAYS
    end

    def self.completed_runs_by_reader(reader_ids)
      history = where(reader_id: reader_ids, active: false).preload(:plan_run).to_a
      days_completed = Checkoff.completed_days_by_participation(history.map(&:id))
      finished = history.select { |membership| days_completed[membership.id] == membership.plan_days }
      # The last written check-off can belong to any day, not necessarily day 270 or 365.
      timestamps = Checkoff.latest_checkoff_at_by_participation(finished.map(&:id))

      finished.each_with_object({}) do |membership, readers|
        date = Bible270.local_time(timestamps[membership.id])&.to_date
        next unless date

        runs = (readers[membership.reader_id] ||= Hash.new { |lengths, days| lengths[days] = [] })
        runs[membership.plan_days] << date
      end
    end

    def alumni? = !active?

    def effective_start_date
      return frozen_start_date if alumni?

      if Bible270.config.allow_reader_start_date && started_on
        started_on
      else
        plan_run.effective_start_date
      end
    end

    # Archive is idempotent: never replace an earlier alumni snapshot at restart.
    # Reader#archive! and PlanRun.restart! hold the run lock when calling this.
    def archive!(on: Bible270.today, shared_start_date: Setting.run_start_date)
      return self if alumni?

      date = if Bible270.config.allow_reader_start_date && reader.started_on
               reader.started_on
             else
               shared_start_date
             end
      update!(active: false, archived_on: on, frozen_start_date: date, started_on: reader.started_on)
      self
    end

    # Reverting a run or reactivating an alumnus must not silently restore a sync link.
    def invalidate_progress_sync_generation
      return unless has_attribute?(:progress_sync_generation) && will_save_change_to_active? && !active?

      self.progress_sync_generation += 1
    end
    private :invalidate_progress_sync_generation

    def ensure_writable!
      unless active? && plan_run.current?
        raise ArchivedProgress, 'Archived progress is read-only; activate the reader in the current run first'
      end

      self
    end
  end
end
