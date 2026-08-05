# frozen_string_literal: true

require 'date'

require 'bible270/version'
require 'bible270/plan'
require 'bible270/email_sign_in'
require 'bible270/names'
require 'bible270/avatars'
require 'bible270/translations'
require 'bible270/favicon'
require 'bible270/configuration'
require 'bible270/engine' if defined?(Rails::Engine)

module Bible270
module_function

  # The plan's idea of today.
  #
  # Date.current follows Rails' Time.zone, which is UTC unless the host app sets
  # it; Date.today follows the machine. A self-hosted reading plan wants the
  # latter, so that is the default, with config.time_zone to override.
  def today
    zone = config.time_zone
    return Date.today if zone.nil? || zone.to_s.empty?

    found = Time.respond_to?(:find_zone) ? Time.find_zone(zone) : nil
    found ? found.today : Date.today
  end
end
