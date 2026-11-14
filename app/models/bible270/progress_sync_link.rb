# frozen_string_literal: true

module Bible270
  class ProgressSyncLink < ApplicationRecord
    self.table_name = 'bible270_progress_sync_links'

    belongs_to :participation, class_name: 'Bible270::Participation'
    has_many :deliveries, class_name: 'Bible270::ProgressSyncDelivery', dependent: :destroy,
                          inverse_of: :progress_sync_link

    attr_readonly :participation_id, :source_generation, :destination, :destination_url,
                  :remote_reader_id, :remote_participation_id, :remote_generation,
                  :remote_name, :email, :plan_fingerprint

    validates :source_generation, :remote_generation, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :remote_reader_id, :remote_participation_id, numericality: { only_integer: true, greater_than: 0 }
    validates :destination, :destination_url, :remote_name, :email, :plan_fingerprint, presence: true
    validates :state, inclusion: { in: %w[active paused] }
    validates :destination, uniqueness: { scope: :participation_id, conditions: -> { where(state: 'active') } }, if: :active?

    scope :active, -> { where(state: 'active') }

    def active? = state == 'active'
    def paused? = state == 'paused'
    def usable? = active? && ProgressSync.link_usable?(self)
    def pending_count = deliveries.where(delivered_at: nil).count
    def delivered_count = deliveries.where.not(delivered_at: nil).count

    def status
      return 'Needs attention' if paused? || last_error.present? || !usable?
      return 'Pending' if pending_count.positive?

      last_synced_at ? 'Synced' : 'Ready'
    end
  end
end
