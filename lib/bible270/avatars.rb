# frozen_string_literal: true

module Bible270
  # What counts as an acceptable avatar. Kept free of Rails and of Active Storage
  # so the rules can be unit tested, and so the engine still loads in an app that
  # has Active Storage disabled.
  module Avatars
    CONTENT_TYPES = %w[image/png image/jpeg image/gif image/webp].freeze

    # Two megabytes. Large enough for a photo off a phone, small enough that
    # nobody's profile page crawls.
    DEFAULT_MAX_BYTES = 2 * 1024 * 1024

  module_function

    def content_types = CONTENT_TYPES

    def max_bytes
      configured = Bible270.config.avatar_max_bytes if Bible270.config.respond_to?(:avatar_max_bytes)
      configured.to_i.positive? ? configured.to_i : DEFAULT_MAX_BYTES
    end

    def acceptable_type?(content_type)
      CONTENT_TYPES.include?(content_type.to_s.downcase.split(';').first.to_s.strip)
    end

    def acceptable_size?(byte_size)
      size = byte_size.to_i
      size.positive? && size <= max_bytes
    end

    # nil when the upload is fine, otherwise the reason — phrased for a reader.
    def problem_with(content_type:, byte_size:)
      return 'must be a PNG, JPEG, GIF or WebP image' unless acceptable_type?(content_type)
      return 'looks empty' unless byte_size.to_i.positive?
      return "must be under #{human_size(max_bytes)}" unless acceptable_size?(byte_size)

      nil
    end

    def human_size(bytes)
      mb = bytes.to_f / (1024 * 1024)
      mb >= 1 ? "#{format('%g', mb.round(1))}MB" : "#{(bytes.to_f / 1024).round}KB"
    end
  end
end
