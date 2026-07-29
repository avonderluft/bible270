# frozen_string_literal: true

module Bible270
  # Runtime state an admin can change without a deploy. Currently just whether
  # this run of the plan is open to new readers.
  class Setting < ApplicationRecord
    self.table_name = 'bible270_settings'

    ENROLLMENT_CLOSED_AT = 'enrollment_closed_at'

    validates :key, presence: true, uniqueness: true

    def self.read(key)
      find_by(key: key.to_s)&.value
    end

    def self.write(key, value)
      record = find_or_initialize_by(key: key.to_s)
      record.value = value
      record.save!
      value
    end

    def self.delete_key(key)
      where(key: key.to_s).delete_all
    end

    # ---- enrolment --------------------------------------------------------

    # Closed either because an admin closed it, or because the app was configured
    # to launch closed.
    def self.enrollment_closed?
      return true if read(ENROLLMENT_CLOSED_AT).present?

      Bible270.config.respond_to?(:enrollment_open) && Bible270.config.enrollment_open == false
    end

    def self.enrollment_closed_at
      raw = read(ENROLLMENT_CLOSED_AT)
      return nil if raw.blank?

      Time.zone ? Time.zone.parse(raw) : Time.parse(raw)
    rescue ArgumentError
      nil
    end

    def self.close_enrollment!(at: Time.current)
      write(ENROLLMENT_CLOSED_AT, at.iso8601)
      true
    end

    def self.open_enrollment!
      delete_key(ENROLLMENT_CLOSED_AT)
      true
    end
  end
end
