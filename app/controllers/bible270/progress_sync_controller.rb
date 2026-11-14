# frozen_string_literal: true

require 'json'
require 'bible270/progress_sync'
require 'bible270/progress_sync/authentication'

module Bible270
  class ProgressSyncController < ActionController::API
    Sync = ProgressSync
    Authentication = Sync::Authentication

    def lookup
      email = @payload['email']
      unless email.is_a?(String) && email.bytesize <= 320 && email.strip.match?(%r{\A[^@\s]+@[^@\s]+\z})
        raise Sync::Conflict, 'A valid reader email is required'
      end

      email = email.strip.downcase
      # Ambiguity includes archived accounts: do not select one identity merely
      # because the other account with the same address is currently inactive.
      readers = matching_readers(email)
      raise Sync::Conflict, 'No unique active reader matches that email' unless readers.length == 1

      reader = readers.first
      membership = Participation.chosen.find_by(reader_id: reader.id)
      with_membership_lock(membership, reader.id) do |current|
        unless reader.reload.email.to_s.strip.downcase == email && matching_readers(email).map(&:id) == [reader.id]
          raise Sync::Conflict, 'No unique active reader matches that email'
        end

        render json: { reader_id: reader.id, participation_id: current.id, generation: current.progress_sync_generation,
                       name: reader.display_name, email: email, plan_fingerprint: Sync.fingerprint }
      end
    end

    def complete
      reader_id = integer!('reader_id', minimum: 1)
      participation_id = integer!('participation_id', minimum: 1)
      generation = integer!('generation', minimum: 0)
      readings = validated_readings!
      membership = Participation.find_by(id: participation_id, reader_id: reader_id)
      with_membership_lock(membership, reader_id) do |current|
        unless current.progress_sync_generation == generation
          raise Sync::Conflict, 'Linked membership changed; explicitly relink'
        end

        existing = current.checkoffs.pluck(:day, :track, :part).to_set
        missing = readings.reject { |triple| existing.include?(triple) }
        Sync.suppress do
          if missing.any?
            Checkoff.insert_all(missing.map do |day, track, part|
              { reader_id: reader_id, participation_id: current.id, day: day, track: track, part: part }
            end)
          end
        end
        render json: { added: missing.length, existing: readings.length - missing.length }
      end
    end

  private

    # Authenticate before calling super: ActionController's instrumentation reads
    # filtered_parameters (and therefore parses JSON) before ordinary callbacks.
    def process_action(*)
      authenticate_request!
      return if performed?

      super
    rescue Sync::Unauthorized
      render json: { error: 'Progress sync authentication failed' }, status: :unauthorized
    rescue Sync::Conflict, ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid
      render json: { error: 'Reader, membership, plan, or completion batch is incompatible' }, status: :conflict
    rescue Sync::Unavailable, Sync::ConfigurationError
      render json: { error: 'Progress sync is unavailable' }, status: :service_unavailable
    rescue JSON::ParserError, EncodingError
      render json: { error: 'Invalid JSON payload' }, status: :bad_request
    end

    def authenticate_request!
      if request.content_length.to_i > Authentication::MAX_BYTES
        render json: { error: 'Progress sync request is too large' }, status: 413
        return
      end
      body = request.body.read(Authentication::MAX_BYTES + 1)
      request.body.rewind
      if body.bytesize > Authentication::MAX_BYTES
        render json: { error: 'Progress sync request is too large' }, status: 413
        return
      end
      config = Bible270.config
      sources = config.progress_sync_sources if config.respond_to?(:progress_sync_sources)
      Authentication.authenticate!(headers: request.headers, sources: sources, method: request.request_method,
                                   path: request.original_fullpath.split('?', 2).first, body: body)
      raise Sync::Unavailable, 'Progress sync migration is not installed' unless Sync.available?

      @payload = JSON.parse(body)
      raise Sync::Conflict, 'A JSON object is required' unless @payload.is_a?(Hash)
      raise Sync::Conflict, 'Reading plans differ' unless @payload['plan_fingerprint'] == Sync.fingerprint
    end

    def matching_readers(email)
      # SQL LOWER/TRIM differ by adapter and do not match Ruby's normalization
      # for all case mappings and surrounding whitespace. Lookup is infrequent;
      # scan only identity columns in batches and stop once ambiguity is proven.
      Reader.select(:id, :email).find_each.lazy.select do |reader|
        reader.email.to_s.strip.downcase == email
      end.take(2).force
    end

    def integer!(key, minimum:)
      value = @payload[key]
      raise Sync::Conflict, 'Invalid linked identity' unless value.is_a?(Integer) && value >= minimum

      value
    end

    def validated_readings!
      readings = @payload['readings']
      unless readings.is_a?(Array) && readings.length <= 5000
        raise Sync::Conflict, 'A batch must contain at most 5000 readings'
      end

      readings.each do |triple|
        unless triple.is_a?(Array) && triple.length == 3
          raise Sync::Conflict, 'Readings must be triples'
        end

        day, track, part = triple
        unless day.is_a?(Integer) && part.is_a?(Integer) && Plan.valid_day?(day) &&
               Plan::TRACKS.key?(track) && Plan.valid_part?(day, track, part)
          raise Sync::Conflict, 'Invalid reading'
        end
      end
      readings.uniq
    end

    def with_membership_lock(membership, reader_id)
      raise Sync::Conflict, 'Linked membership no longer exists' unless membership

      PlanRun.find(membership.plan_run_id).with_lock do
        Reader.find(reader_id).with_lock do
          membership.reload
          unless membership.active? && PlanRun.where(id: membership.plan_run_id, current: true).exists? &&
                 Participation.chosen.where(id: membership.id).exists? && @payload['plan_fingerprint'] == Sync.fingerprint
            raise Sync::Conflict, 'Linked membership is no longer active or compatible'
          end

          yield membership
        end
      end
    end
  end
end
