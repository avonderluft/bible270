# frozen_string_literal: true

module Bible270
  # A single reader marking one track (ot / nt / pp) read on one day.
  class Checkoff < ApplicationRecord
    self.table_name = 'bible270_checkoffs'

    RecentActivity = Struct.new(:occurred_at, :day, :track, :part, :day_completed?, keyword_init: true)

    belongs_to :reader, class_name: 'Bible270::Reader'
    belongs_to :participation, class_name: 'Bible270::Participation', inverse_of: :checkoffs

    after_create :capture_progress_sync
    before_validation :assign_participation
    validate :participation_matches_reader
    validate :participation_is_writable
    around_save :with_writable_participation
    around_destroy :with_writable_participation

    validates :day, inclusion: { in: ->(checkoff) { 1..(checkoff.participation&.plan_days || Plan::DAYS) } }
    validates :track, inclusion: { in: Plan::TRACKS.keys }
    validates :track, uniqueness: { scope: %i[participation_id day part] }
    validates :part, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate  :track_present_on_day
    validate  :part_within_reading

    scope :within_run_schedule, -> {
      where(day: 1..Plan::DAYS).or(
        where(day: (Plan::DAYS + 1)..Plan::EXTENDED_DAYS, participation_id: Participation.with_plus95.select(:id))
      )
    }

    # Legacy callers (including historical chapter backfills) use insert_all
    # without a membership. Resolve those IDs in bulk without creating membership
    # or reactivating anyone. Explicit participation IDs remain a trusted bulk API.
    def self.insert_all(attributes, **)
      return super unless column_names.include?('participation_id') && attributes.any? { |row| !row.key?(:participation_id) }

      transaction do
        ids = attributes.filter_map { |row| row[:reader_id] unless row.key?(:participation_id) }.uniq
        memberships = Participation.chosen.where(reader_id: ids).index_by(&:reader_id)
        # Use the same locks as archive/restart, in a stable order for batches.
        # Keep them until after super, not merely until validation has finished.
        runs = PlanRun.where(id: memberships.values.map(&:plan_run_id).uniq).order(:id).lock.index_by(&:id)
        memberships.each_value do |membership|
          membership.reload
          membership.plan_run = runs.fetch(membership.plan_run_id)
          membership.ensure_writable!
        end
        attributes = attributes.map do |row|
          next row if row.key?(:participation_id)

          membership = memberships.fetch(row[:reader_id])
          if row[:day].to_i > membership.plan_days
            raise ArgumentError, 'Check-off day is outside the run schedule'
          end

          row.merge(participation_id: membership.id)
        end
        super
      end
    end

    def self.completed_days_by_participation(participation_ids, through: nil)
      scope = within_run_schedule.where(participation_id: participation_ids)
      scope = scope.where(day: 1..through) if through
      scope.group(:participation_id, :day).count.each_with_object(Hash.new(0)) do |((participation_id, day), count), totals|
        totals[participation_id] += 1 if count >= Plan.total_parts(day)
      end
    end

    def self.latest_checkoff_at_by_participation(participation_ids, through: nil)
      return {} if participation_ids.empty?

      scope = within_run_schedule.where(participation_id: participation_ids)
      scope = scope.where(day: 1..through) if through
      scope.group(:participation_id).maximum(:created_at)
    end

    # The most recently created check-off still present for each reader. This uses
    # three bulk queries regardless of the number of readers displayed in Admin.
    def self.recent_activity_by_reader(reader_ids)
      latest_ids = within_run_schedule.where(reader_id: reader_ids, participation_id: Participation.chosen.select(:id))
        .group(:reader_id).maximum(:id).values
      latest_checkoffs = where(id: latest_ids).index_by(&:reader_id)
      day_counts = recent_activity_day_counts(latest_checkoffs.values)

      latest_checkoffs.transform_values do |checkoff|
        RecentActivity.new(
          occurred_at: checkoff.created_at,
          day: checkoff.day,
          track: checkoff.track,
          part: checkoff.part,
          day_completed?: day_counts.fetch([checkoff.reader_id, checkoff.day], 0) >= Plan.total_parts(checkoff.day)
        )
      end
    end

    def self.recent_activity_day_counts(checkoffs)
      return {} if checkoffs.empty?

      where(participation_id: checkoffs.map(&:participation_id), day: checkoffs.map(&:day))
        .group(:reader_id, :day).count
    end
    private_class_method :recent_activity_day_counts

  private

    def capture_progress_sync
      ProgressSync.capture(participation, [[day, track, part]])
    end

    def assign_participation
      self.participation ||= reader&.participation
    end

    def participation_matches_reader
      if persisted? && (will_save_change_to_reader_id? || will_save_change_to_participation_id?)
        errors.add(:participation, 'cannot change the owner of existing progress')
      end
      return unless participation && participation.reader_id != reader_id

      errors.add(:participation, 'must belong to the same reader')
    end

    def participation_is_writable
      return unless participation
      return if Participation.active.where(id: participation.id).exists?

      errors.add(:participation, 'has archived progress and is read-only')
    end

    # Share the run lock with restart/archive, including the actual write, not
    # just its validation. Cascading identity deletion intentionally removes history.
    def with_writable_participation
      return yield if destroyed_by_association

      run = participation.plan_run
      run.with_lock do
        participation.reload
        participation.plan_run = run
        participation.ensure_writable!
        raise PlanRun::StaleRun, 'The check-off day is outside the run schedule' if day && day > participation.plan_days

        yield
      end
    end

    def track_present_on_day
      return if day.nil? || track.nil?
      return if Plan.present_tracks(day).include?(track)

      errors.add(:track, "is not part of day #{day}")
    end

    # Part 0 is the first chapter of the day's reading; an Old Testament reading
    # of three chapters has parts 0, 1 and 2.
    def part_within_reading
      return if day.nil? || track.nil? || part.nil?
      return if Plan.valid_part?(day, track, part)

      errors.add(:part, "is not part of the #{track} reading on day #{day}")
    end
  end
end
