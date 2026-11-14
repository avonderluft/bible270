# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'openssl'
require 'timeout'
require 'bible270/progress_sync'
require 'bible270/progress_sync/authentication'

module Bible270
  module ProgressSync
    class Client
      REQUEST_TIMEOUT = 30

      def initialize(destination_key)
        config = Bible270.config
        @source = config.progress_sync_instance_id if config.respond_to?(:progress_sync_instance_id)
        entries = config.progress_sync_destinations if config.respond_to?(:progress_sync_destinations)
        entry = entries[destination_key.to_s] if entries.is_a?(Hash)
        unless Authentication.valid_source?(@source) && entry.is_a?(Hash)
          raise ConfigurationError, 'Progress sync requires a source instance ID and an allowlisted destination'
        end

        @url = (entry[:url] || entry['url']).to_s.chomp('/')
        @secret = entry[:secret] || entry['secret']
        @uri = URI.parse(@url)
        unless valid_destination?
          raise ConfigurationError, 'Destination requires an HTTPS mount URL and a secret of at least 32 characters'
        end
      rescue URI::InvalidURIError
        raise ConfigurationError, 'Destination URL is invalid'
      end

      def lookup(email)
        email = email.to_s.strip.downcase
        unless valid_email?(email)
          raise Conflict, 'A valid destination reader email is required'
        end

        result = post('lookup', email: email, plan_fingerprint: ProgressSync.fingerprint)
        unless positive_integer?(result['reader_id']) && positive_integer?(result['participation_id']) &&
               nonnegative_integer?(result['generation']) && result['name'].is_a?(String) && !result['name'].strip.empty? &&
               valid_email?(result['email']) && result['email'].strip.downcase == email &&
               result['plan_fingerprint'] == ProgressSync.fingerprint
          raise Conflict, 'Destination returned an incompatible reader or reading plan'
        end

        result
      end

      def complete(link, readings)
        unless link.destination_url == @url
          raise ConfigurationError, 'Destination URL changed; explicitly relink'
        end
        unless readings.is_a?(Array) && readings.length <= 5000
          raise Conflict, 'A completion batch must contain at most 5000 readings'
        end

        result = post('complete', reader_id: link.remote_reader_id, participation_id: link.remote_participation_id,
                                  generation: link.remote_generation, plan_fingerprint: link.plan_fingerprint, readings: readings)
        unless nonnegative_integer?(result['added']) && nonnegative_integer?(result['existing']) &&
               result['added'] + result['existing'] == readings.uniq.length
          raise Unavailable, 'Destination returned invalid completion counts'
        end

        result
      end

    private

      def valid_destination?
        @uri.is_a?(URI::HTTPS) && @uri.host && !@uri.userinfo && !@uri.query && !@uri.fragment &&
          @secret.is_a?(String) && @secret.length >= 32
      end

      def positive_integer?(value) = value.is_a?(Integer) && value.positive?
      def nonnegative_integer?(value) = value.is_a?(Integer) && value >= 0
      def valid_email?(value) = value.is_a?(String) && value.bytesize <= 320 && value.strip.match?(%r{\A[^@\s]+@[^@\s]+\z})

      def post(action, payload)
        body = JSON.generate(payload)
        raise Conflict, 'Progress sync request is too large' if body.bytesize > Authentication::MAX_BYTES

        path = "#{@uri.path.chomp('/')}/progress-sync/#{action}"
        request = Net::HTTP::Post.new(path)
        request['Content-Type'] = 'application/json'
        request['Accept'] = 'application/json'
        # Disable Net::HTTP's automatic decompression so the byte limit applies to
        # the actual response we parse, not an unbounded inflated buffer.
        request['Accept-Encoding'] = 'identity'
        Authentication.headers(secret: @secret, source: @source, method: 'POST', path: path, body: body).each do |key, value|
          request[key] = value
        end
        request.body = body
        http = Net::HTTP.new(@uri.host, @uri.port, nil)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.open_timeout = 5
        http.read_timeout = 10
        http.write_timeout = 10
        http.max_retries = 0
        response_body = +''
        status = nil
        # Per-operation timeouts do not bound a peer that keeps trickling bytes.
        # Finish well before the outbox lease expires, including TLS and cleanup.
        Timeout.timeout(REQUEST_TIMEOUT) do
          http.start do |connection|
            connection.request(request) do |response|
              status = response.code.to_i
              # Never follow redirects, and never expose response error pages.
              check_status!(status)
              if response['Content-Length'].to_i > Authentication::MAX_BYTES
                raise Unavailable, 'Destination response is too large'
              end

              response.read_body do |chunk|
                raise Unavailable, 'Destination response is too large' if response_body.bytesize + chunk.bytesize > Authentication::MAX_BYTES

                response_body << chunk
              end
            end
          end
        end
        result = JSON.parse(response_body)
        raise Unavailable, 'Destination returned invalid JSON' unless result.is_a?(Hash)

        result
      rescue JSON::ParserError, EncodingError
        raise Unavailable, 'Destination returned invalid JSON', cause: nil
      rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
        raise Unavailable, 'Progress sync destination could not be reached securely', cause: nil
      end

      def check_status!(status)
        return if status == 200

        case status
        when 401, 403 then raise Unauthorized, 'Destination rejected progress sync authentication'
        when 400, 404, 409, 410, 413, 422 then raise Conflict, 'Destination rejected the linked reader, reading plan, or completion batch'
        when 300..399 then raise ConfigurationError, 'Progress sync destination redirects are not allowed'
        else raise Unavailable, 'Progress sync destination is temporarily unavailable'
        end
      end
    end
  end
end
