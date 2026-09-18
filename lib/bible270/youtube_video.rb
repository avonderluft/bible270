# frozen_string_literal: true

require 'uri'

module Bible270
  module YouTubeVideo
    HOSTS = %w[youtube.com www.youtube.com m.youtube.com youtu.be www.youtu.be].freeze
    SHORT_HOSTS = %w[youtu.be www.youtu.be].freeze
    ID_PATTERN = %r{\A[A-Za-z0-9_-]{11}\z}

  module_function

    def id_from_url(url)
      return if url.match?(%r{[[:space:][:cntrl:]]})

      uri = URI.parse(url)
      return unless uri.is_a?(URI::HTTP) && HOSTS.include?(uri.host&.downcase)
      return if uri.userinfo || url.match?(%r{%(?![0-9a-f]{2})}i)
      # Match the authority literally too: URI accepts empty ports and normalizes
      # explicit default ports, which would otherwise conceal malformed input.
      return unless url.match?(%r{\Ahttps?://#{Regexp.escape(uri.host)}(?::#{uri.default_port})?/}i)

      id = candidate_id(uri)
      id if id&.match?(ID_PATTERN)
    rescue URI::InvalidURIError, ArgumentError
      nil
    end

    def candidate_id(uri)
      if SHORT_HOSTS.include?(uri.host.downcase)
        uri.path.delete_prefix('/')
      elsif uri.path == '/watch'
        ids = URI.decode_www_form(uri.query.to_s).filter_map { |key, value| value if key == 'v' }
        ids.first if ids.one?
      else
        uri.path.match(%r{\A/(?:shorts|live|embed)/([A-Za-z0-9_-]{11})\z})&.[](1)
      end
    end
    private_class_method :candidate_id
  end
end
