# frozen_string_literal: true

require 'date'

require 'bible270/version'
require 'bible270/plan'
require 'bible270/email_sign_in'
require 'bible270/names'
require 'bible270/mentions'
require 'bible270/avatars'
require 'bible270/translations'
require 'bible270/favicon'
require 'bible270/configuration'
require 'bible270/daily_reminders'
require 'bible270/engine' if defined?(Rails::Engine)

module Bible270
module_function

  # The plan's idea of today.
  #
  # Date.current follows Rails' Time.zone, which is UTC unless the host app sets
  # it; Date.today follows the machine. A self-hosted reading plan wants the
  # latter, so that is the default, with config.time_zone to override.
  def today
    local_time(Time.now).to_date
  end

  # A stored timestamp in the plan's own zone.
  #
  # created_at and friends come back in Rails' Time.zone, which is UTC unless the
  # host app sets it — so a reflection written at 5pm in Los Angeles was being
  # shown as the next day. This is the same rule Bible270.today follows: the
  # machine's zone, or config.time_zone when one is given.
  def local_time(time)
    return nil if time.nil?

    zone = config.time_zone
    if zone.to_s.empty?
      time.getlocal
    else
      found = Time.respond_to?(:find_zone) ? Time.find_zone(zone) : nil
      found ? time.in_time_zone(found) : time.getlocal
    end
  end
end
