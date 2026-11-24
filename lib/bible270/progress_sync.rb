# frozen_string_literal: true

require 'digest'
require 'json'
require 'securerandom'
require 'uri'
require 'bible270/plan'

module Bible270
  module ProgressSync
    class Error < StandardError; end
    class ConfigurationError < Error; end
    class Unavailable < Error; end
    class Conflict < Error; end

    class Unauthorized < Error; end

    autoload :Client, 'bible270/progress_sync/client'

    MAX_ATTEMPTS = 8
    LEASE_SECONDS = 300
    SUPPRESSION_KEY = :bible270_progress_sync_suppressed

  module_function

    def available?
      return false unless defined?(ActiveRecord::Base)

      connection = ActiveRecord::Base.connection
      %w[bible270_progress_sync_links bible270_progress_sync_deliveries bible270_participations].all? do |table|
        connection.data_source_exists?(table)
      end && connection.column_exists?(:bible270_participations, :progress_sync_generation)
    rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
      false
    end

    # Recompute from the actual schedule, not the gem version or a long-lived
    # digest cache. Include empty readings and the positional checkoff semantics.
    # Unbound lookups default to the current run's length. Membership-bound
    # operations supply the member's effective length instead.
    def fingerprint(days: current_plan_days)
      schedule = (1..days).map do |day|
        [day, Plan::TRACKS.keys.sort.map { |track| [track, Plan.parts_for(day, track).each_with_index.map { |text, part| [part, text] }] }]
      end
      Digest::SHA256.hexdigest(JSON.generate(['bible270:completion:day-one-based:part-zero-based:v1', schedule]))
    end

    # A fingerprint describes the positions on the wire, not a reader's current length.
    def fingerprint_days(digest)
      return Plan::DAYS if digest == fingerprint(days: Plan::DAYS)
      return Plan::EXTENDED_DAYS if digest == fingerprint(days: Plan::EXTENDED_DAYS)

      nil
    end

    def current_plan_days
      return Plan::DAYS unless defined?(PlanRun)

      PlanRun.find_by(current: true)&.plan_days || Plan::DAYS
    rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
      Plan::DAYS
    end
    private_class_method :current_plan_days

    def suppress
      previous = Thread.current.thread_variable_get(SUPPRESSION_KEY)
      Thread.current.thread_variable_set(SUPPRESSION_KEY, true)
      yield
    ensure
      Thread.current.thread_variable_set(SUPPRESSION_KEY, previous)
    end

    def suppressed? = !!Thread.current.thread_variable_get(SUPPRESSION_KEY)

    # Called inside the local checkoff transaction; never contacts the client.
    # Returning an array also supports several allowlisted destinations per reader.
    def capture(participation, readings)
      return [] if suppressed? || !destinations.is_a?(Hash) || destinations.empty? || !available? || !participation&.persisted?

      links = ProgressSyncLink.active.where(participation_id: participation.id)
      return [] unless links.exists?

      captured = []
      with_source_lock(participation) do |membership, run|
        days = membership.plan_days
        triples = normalize_readings(readings, days: days)
        next if triples.empty?

        links.order(:id).lock.each do |link|
          validate_link!(link, membership: membership, run: run)
          unless membership.progress_sync_generation == participation.progress_sync_generation
            raise Conflict, 'Source membership changed; explicitly relink this reader'
          end

          captured << enqueue!(link, triples)
        rescue ConfigurationError, Conflict, Unauthorized => e
          pause!(link, e.message)
        end
      end
      captured
    end

    def lookup(destination:, email:, plan_fingerprint: nil)
      ensure_available!
      ensure_network_outside_transaction!
      configured_destination!(destination)
      Client.new(destination.to_s).lookup(normalize_email(email), plan_fingerprint: plan_fingerprint)
    end

    # A paused link is replaced, never reactivated or retargeted. The caller's
    # confirmation of this API is the explicit consent to create the replacement.
    def link!(reader:, destination:, remote:, expected_participation_id:)
      ensure_available!
      destination = destination.to_s
      destination_settings = configured_destination!(destination)
      remote = remote.to_h.transform_keys(&:to_s)
      attributes = {
        destination: destination, destination_url: destination_settings.fetch(:url),
        remote_reader_id: remote_integer!(remote, 'reader_id', minimum: 1),
        remote_participation_id: remote_integer!(remote, 'participation_id', minimum: 1),
        remote_generation: remote_integer!(remote, 'generation', minimum: 0),
        remote_name: remote['name'].to_s.strip, email: normalize_email(remote['email'])
      }
      membership = Participation.find_by(id: expected_participation_id, reader_id: reader.id)
      raise Conflict, 'Source membership changed; reload before linking' unless membership

      result = nil
      with_source_lock(membership) do |current, run|
        validate_membership!(current, run: run)
        digest = remote['plan_fingerprint']
        unless fingerprint_days(digest)
          raise Conflict, 'Destination uses a different reading plan; look up the destination again'
        end
        raise ConfigurationError, 'Destination URL changed; look up the destination again' unless configured_destination!(destination) == destination_settings

        existing = ProgressSyncLink.active.where(participation_id: current.id, destination: destination).lock.first
        if existing
          begin
            validate_link!(existing, membership: current, run: run)
            binding_changed = %i[remote_reader_id remote_participation_id remote_generation].any? do |attribute|
              existing.public_send(attribute) != attributes.fetch(attribute)
            end
            pause!(existing, 'Destination reader binding changed; explicitly replaced') if binding_changed
          rescue ConfigurationError, Conflict, Unauthorized => e
            pause!(existing, e.message)
          end
        end
        result = ProgressSyncLink.create!(attributes.merge(participation: current, plan_fingerprint: digest,
                                                           source_generation: current.progress_sync_generation))
      end
      result
    end

    # Add-only snapshot. Repeating this is safe: destination checkoff uniqueness
    # is the idempotency boundary. No local progress or dates are changed.
    # Returns the new delivery, or nil when the current snapshot is empty.
    def copy_existing!(link)
      ensure_available!
      return nil if suppressed?

      result = nil
      failure = nil
      with_source_lock(link.participation) do |membership, run|
        link.reload.lock!
        begin
          validate_link!(link, membership: membership, run: run)
          days = membership.plan_days
          rows = membership.checkoffs.where(day: 1..days).order(:day, :track, :part).pluck(:day, :track, :part)
          triples = normalize_readings(rows, days: days)
          result = enqueue!(link, triples) if triples.any?
        rescue ConfigurationError, Conflict, Unauthorized => e
          pause!(link, e.message)
          failure = e
        end
      end
      # Raise after committing the pause, including when an admin repeats copy.
      raise failure if failure

      result
    end

    def link_usable?(link)
      return false unless available?

      validate_link!(link)
      true
    rescue Error, ActiveRecord::RecordNotFound
      false
    end

    # Returns successful delivery count, not reading count. Scheduling this task
    # frequently is sufficient; there is no job adapter dependency.
    def deliver_pending(limit: 100, delivery_id: nil)
      return 0 unless available?

      ensure_network_outside_transaction!
      count = 0
      pending = ProgressSyncDelivery.due.where(progress_sync_link_id: ProgressSyncLink.active.select(:id))
      pending = pending.where(id: delivery_id) unless delivery_id.nil?
      pending.order(:next_attempt_at, :id).limit(limit).pluck(:id).each do |id|
        claimed = claim_delivery(id)
        next unless claimed

        delivery, exhausted = claimed
        begin
          raise Conflict, 'Delivery retry limit reached; explicitly relink to retry' if exhausted

          link = prepare_delivery!(delivery)
          # No transaction or row lock survives prepare_delivery!. Tokens fence
          # late HTTP responses if an expired lease was reclaimed by a worker.
          response = Client.new(link.destination).complete(link, delivery.readings)
          counts = response_counts!(response, expected_count: delivery.readings.uniq.length)
          count += 1 if finish_delivery!(delivery, counts: counts)
        rescue Error => e
          finish_delivery!(delivery, error: e)
        end
      end
      count
    end

    def destinations
      config = Bible270.config
      config.respond_to?(:progress_sync_destinations) ? (config.progress_sync_destinations || {}) : {}
    end
    private_class_method :destinations

    def ensure_available!
      raise Unavailable, 'Progress sync migration is not installed' unless available?
    end
    private_class_method :ensure_available!

    def ensure_network_outside_transaction!
      return unless ActiveRecord::Base.connection.transaction_open?

      raise ConfigurationError, 'Progress sync HTTP cannot run inside a database transaction'
    end
    private_class_method :ensure_network_outside_transaction!

    def normalize_email(email)
      value = email.to_s.strip.downcase
      raise Conflict, 'A valid destination reader email is required' unless value.match?(%r{\A[^@\s]+@[^@\s]+\z})

      value
    end
    private_class_method :normalize_email

    def configured_destination!(destination)
      config = Bible270.config
      unless config.respond_to?(:progress_sync_instance_id) && config.progress_sync_instance_id.to_s.strip.present?
        raise ConfigurationError, 'A progress sync source instance ID is required'
      end

      entries = destinations
      raise ConfigurationError, 'Progress sync destinations must be an allowlist hash' unless entries.is_a?(Hash)

      entry = entries[destination.to_s]
      raise ConfigurationError, 'Destination is not allowlisted' unless entry.is_a?(Hash)

      url = (entry[:url] || entry['url']).to_s.chomp('/')
      secret = (entry[:secret] || entry['secret']).to_s
      uri = URI.parse(url)
      unless uri.is_a?(URI::HTTPS) && uri.host.present? && !uri.userinfo && !uri.query && !uri.fragment && secret.length >= 32
        raise ConfigurationError, 'Destination requires an HTTPS mount URL and a secret of at least 32 characters'
      end

      { url: url, secret: secret }
    rescue URI::InvalidURIError
      raise ConfigurationError, 'Destination URL is invalid'
    end
    private_class_method :configured_destination!

    def remote_integer!(remote, key, minimum:)
      value = Integer(remote.fetch(key).to_s, 10)
      raise ArgumentError if value < minimum

      value
    rescue KeyError, ArgumentError
      raise Conflict, "Destination returned an invalid #{key}"
    end
    private_class_method :remote_integer!

    def normalize_readings(readings, days:)
      Array(readings).map do |triple|
        unless triple.is_a?(Array) && triple.length == 3
          raise Conflict, 'Readings must be [day, track, part] triples'
        end

        day, track, part = triple
        unless Plan.valid_day?(day, days: days) && Plan::TRACKS.key?(track) && Plan.valid_part?(day, track, part)
          raise Conflict, 'A completion does not belong to the current reading plan'
        end

        [day, track, part]
      end.uniq
    end
    private_class_method :normalize_readings

    def with_source_lock(participation)
      # Fresh instances avoid stale association caches and lock! rejecting a
      # caller's dirty Reader. Match archive/restart's run -> reader lock order.
      run = PlanRun.find(participation.plan_run_id)
      run.with_lock do
        Reader.find(participation.reader_id).with_lock do
          yield Participation.find(participation.id), run
        end
      end
    end
    private_class_method :with_source_lock

    def validate_membership!(membership, run:)
      unless membership.active? && membership.plan_run_id == run.id && run.current? &&
             Participation.chosen.where(id: membership.id).exists?
        raise Conflict, 'Source reader is no longer active in the linked run; explicitly relink'
      end
    end
    private_class_method :validate_membership!

    def validate_link!(link, membership: nil, run: nil)
      raise Conflict, 'Progress sync link is paused; explicitly relink' unless link.active?

      membership ||= Participation.find(link.participation_id)
      run ||= membership.plan_run
      validate_membership!(membership, run: run)
      unless membership.id == link.participation_id && membership.progress_sync_generation == link.source_generation
        raise Conflict, 'Source membership generation changed; explicitly relink'
      end

      unless configured_destination!(link.destination).fetch(:url) == link.destination_url
        raise ConfigurationError, 'Destination URL changed; explicitly relink'
      end

      raise Conflict, 'Reading plan changed; explicitly relink' unless fingerprint_days(link.plan_fingerprint)

      true
    end
    private_class_method :validate_link!

    def enqueue!(link, triples)
      link.deliveries.create!(readings: triples, next_attempt_at: Time.current)
    end
    private_class_method :enqueue!

    def pause!(link, message)
      link.update!(state: 'paused', last_error: message.to_s.truncate(1000))
    end
    private_class_method :pause!

    def claim_delivery(id)
      delivery = ProgressSyncDelivery.find_by(id: id)
      return unless delivery

      now = Time.current
      token = SecureRandom.uuid
      attempts = delivery.attempts
      # A single compare-and-swap UPDATE works on SQLite as well as PostgreSQL;
      # no select-lock transaction is held while contacting the destination.
      claimed = ProgressSyncDelivery.due(now).where(id: id, attempts: attempts,
                                                    progress_sync_link_id: ProgressSyncLink.active.select(:id)).update_all(
                                                      claim_token: token, locked_until: now + LEASE_SECONDS,
                                                      attempts: [attempts + 1, MAX_ATTEMPTS].min, updated_at: now
                                                    )
      return unless claimed == 1

      delivery.reload
      # Another worker can reclaim only after lease expiry. Do not use its token.
      return unless delivery.claim_token == token

      [delivery, attempts >= MAX_ATTEMPTS]
    end
    private_class_method :claim_delivery

    def prepare_delivery!(delivery)
      link = ProgressSyncLink.find(delivery.progress_sync_link_id)
      with_source_lock(link.participation) do |membership, run|
        link.reload.lock!
        validate_link!(link, membership: membership, run: run)
        # A length toggle does not undo check-offs already captured for delivery.
        normalize_readings(delivery.readings, days: Plan::EXTENDED_DAYS)
        unless ProgressSyncDelivery.where(id: delivery.id, claim_token: delivery.claim_token, delivered_at: nil)
            .where('locked_until > ?', Time.current).exists?
          raise Unavailable, 'Delivery lease expired before sending'
        end
      end
      link
    rescue ActiveRecord::RecordNotFound
      raise Conflict, 'Source membership or progress sync link no longer exists'
    end
    private_class_method :prepare_delivery!

    def response_counts!(response, expected_count:)
      counts = %w[added existing].map { |key| response.fetch(key) }
      unless counts.all? { |value| value.is_a?(Integer) && value >= 0 } && counts.sum == expected_count
        raise Unavailable, 'Destination returned invalid completion counts'
      end

      counts
    rescue KeyError, NoMethodError
      raise Unavailable, 'Destination returned invalid completion counts'
    end
    private_class_method :response_counts!

    def finish_delivery!(delivery, counts: nil, error: nil)
      finished = false
      ProgressSyncLink.transaction do
        link = ProgressSyncLink.lock.find_by(id: delivery.progress_sync_link_id)
        next unless link

        current = ProgressSyncDelivery.lock.find_by(id: delivery.id, claim_token: delivery.claim_token, delivered_at: nil)
        next unless current

        now = Time.current
        if error
          message = error.message.to_s.truncate(1000)
          current.update!(last_error: message, claim_token: nil, locked_until: nil,
                          next_attempt_at: now + [60 * (2**(current.attempts - 1)), 21_600].min)
          if !error.is_a?(Unavailable) || current.attempts >= MAX_ATTEMPTS
            pause!(link, message)
          elsif link.active?
            link.update!(last_error: message)
          end
        else
          current.update!(delivered_at: now, last_error: nil, claim_token: nil, locked_until: nil)
          attributes = { last_synced_at: now, last_added: counts[0], last_existing: counts[1] }
          attributes[:last_error] = nil if link.active?
          link.update!(attributes)
          finished = true
        end
      end
      finished
    end
    private_class_method :finish_delivery!
  end
end
