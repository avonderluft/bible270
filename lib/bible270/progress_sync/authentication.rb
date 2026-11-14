# frozen_string_literal: true

require 'openssl'
require 'digest'
require 'active_support/security_utils'

module Bible270
  module ProgressSync
    module Authentication
      VERSION = '1'
      MAX_BYTES = 256 * 1024
      TTL = 300
      SOURCE_HEADER = 'X-Bible270-Sync-Source'
      TIMESTAMP_HEADER = 'X-Bible270-Sync-Timestamp'
      SIGNATURE_HEADER = 'X-Bible270-Sync-Signature'
      VERSION_HEADER = 'X-Bible270-Sync-Version'

    module_function

      def valid_source?(source)
        source.is_a?(String) && source.match?(%r{\A[A-Za-z0-9._:-]{1,128}\z})
      end

      def signature(secret:, source:, timestamp:, method:, path:, body:) # rubocop:disable Metrics/ParameterLists
        message = [VERSION, source, timestamp, method.upcase, path, Digest::SHA256.hexdigest(body)].join("\n")
        OpenSSL::HMAC.hexdigest('SHA256', secret, message)
      end

      def headers(secret:, source:, method:, path:, body:, timestamp: Time.now.to_i.to_s) # rubocop:disable Metrics/ParameterLists
        {
          SOURCE_HEADER => source, TIMESTAMP_HEADER => timestamp, VERSION_HEADER => VERSION,
          SIGNATURE_HEADER => signature(secret: secret, source: source, timestamp: timestamp, method: method, path: path, body: body)
        }
      end

      def authenticate!(headers:, sources:, method:, path:, body:, now: Time.now.to_i) # rubocop:disable Metrics/ParameterLists
        source = headers[SOURCE_HEADER]
        timestamp = headers[TIMESTAMP_HEADER]
        supplied = headers[SIGNATURE_HEADER]
        unless headers[VERSION_HEADER] == VERSION && valid_source?(source) &&
               timestamp.is_a?(String) && timestamp.match?(%r{\A\d{1,12}\z}) &&
               (now - timestamp.to_i).abs <= TTL && supplied.is_a?(String) && supplied.match?(%r{\A[0-9a-f]{64}\z})
          raise Unauthorized, 'Progress sync authentication failed'
        end

        entry = sources.is_a?(Hash) ? sources[source] : nil
        secret = entry.is_a?(Hash) ? (entry[:secret] || entry['secret']) : nil
        unless secret.is_a?(String) && secret.length >= 32
          raise Unauthorized, 'Progress sync authentication failed'
        end

        expected = signature(secret: secret, source: source, timestamp: timestamp, method: method, path: path, body: body)
        unless ActiveSupport::SecurityUtils.secure_compare(expected, supplied)
          raise Unauthorized, 'Progress sync authentication failed'
        end

        source
      end
    end
  end
end
