# frozen_string_literal: true

module Bible270
  class Participation < ApplicationRecord
    self.table_name = 'bible270_participations'

    class ArchivedProgress < StandardError; end

    belongs_to :reader, class_name: 'Bible270::Reader', inverse_of: :participations
    belongs_to :plan_run, class_name: 'Bible270::PlanRun', inverse_of: :participations
    has_many :checkoffs, class_name: 'Bible270::Checkoff', dependent: :destroy, inverse_of: :participation

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

    def ensure_writable!
      unless active? && plan_run.current?
        raise ArchivedProgress, 'Archived progress is read-only; activate the reader in the current run first'
      end

      self
    end
  end
end
