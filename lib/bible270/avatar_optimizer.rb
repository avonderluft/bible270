# frozen_string_literal: true

require 'tempfile'
require 'zlib'
require_relative 'configuration'

module Bible270
  # File-only avatar processing; no Rails, Active Storage, or original-file writes.
  class AvatarOptimizer
    VERSION = '1'
    SIZE = 256
    # Bounds the first frame's decoded pixels before materializing it. This is not
    # a process-memory cap: channels, bit depth, and working buffers also use RAM.
    MAX_PIXELS = 40_000_000
    # PNG text is discarded without inflation. PNG permits only one iCCP chunk,
    # so rejecting duplicates makes this an aggregate expanded ICC limit too.
    # This bounds that metadata attack, not total Ruby/native process memory.
    MAX_PNG_ICC_BYTES = 4 * 1024 * 1024
    PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze
    private_constant :PNG_SIGNATURE

    class Error < StandardError; end

    DECODERS = {
      'VipsForeignLoadPngBuffer' => 'image/png',
      'VipsForeignLoadJpegBuffer' => 'image/jpeg',
      'VipsForeignLoadNsgifBuffer' => 'image/gif',
      'VipsForeignLoadWebpBuffer' => 'image/webp'
    }.freeze
    private_constant :DECODERS

    class << self
      # Yields a readable, rewound WebP Tempfile and returns the block's result.
      # The output is closed/unlinked even on exceptions or non-local block exits.
      # Input must remain stable while being read; originals remain caller-owned.
      def open(path, content_type:, byte_size:)
        raise ArgumentError, 'AvatarOptimizer.open requires a block' unless block_given?

        type = content_type.to_s.downcase.split(';').first.to_s.strip
        data = read_source(path, type, byte_size)
        data = sanitize_png(data) if data.start_with?(PNG_SIGNATURE)
        load_backend!
        output = new_output
        write_output(data, type, output.path)
        output.rewind
        yield output
      ensure
        output&.close!
      end

    private

      def read_source(path, content_type, byte_size)
        unless Avatars.acceptable_type?(content_type)
          raise Error, 'Avatar must be a PNG, JPEG, GIF or WebP image.'
        end
        unless byte_size.is_a?(Integer) && byte_size.positive?
          raise Error, 'Avatar byte size must be a positive integer; upload the file again.'
        end
        raise Error, 'Avatar must be a readable regular file; upload it again.' unless File.file?(path)

        limit = Avatars.max_bytes
        size = File.size(path)
        if size > limit || byte_size > limit
          raise Error, "Avatar must be no larger than #{Avatars.human_size(limit)}."
        end
        if size.zero? || size != byte_size
          raise Error, 'Avatar file size does not match the upload; upload it again.'
        end

        # A bounded snapshot avoids path-option injection, decoder TOCTOU, and
        # unbounded reads if a file grows between stat and read.
        data = File.binread(path, limit + 1)
        unless data.bytesize == size
          raise Error, 'Avatar file changed while being read; upload it again.'
        end

        data
      rescue SystemCallError, IOError, ArgumentError, TypeError
        raise Error, 'Avatar file could not be read; upload a readable file again.'
      end

      def sanitize_png(data)
        sanitized = PNG_SIGNATURE.dup
        seen = {}
        image_data_ended = false
        each_png_chunk(data) do |type, payload, encoded|
          invalid_png! unless seen['IHDR'] || type == 'IHDR'
          image_data_ended = true if seen['IDAT'] && type != 'IDAT'
          invalid_png! if type == 'IDAT' && image_data_ended
          check_png_chunk(type, payload, seen)
          seen[type] = true if %w[IHDR PLTE IDAT iCCP eXIf].include?(type)
          # Keep eXIf and bounded iCCP for orientation/colour conversion. All
          # text (including compressed XMP/raw profiles) is unnecessary here.
          sanitized << encoded unless %w[tEXt zTXt iTXt].include?(type)
        end
        sanitized
      end

      def check_png_chunk(type, payload, seen)
        invalid_png! if %w[IHDR PLTE iCCP eXIf].include?(type) && seen[type]
        case type
        when 'IHDR'
          invalid_png! unless payload.bytesize == 13
          check_dimensions(*payload.unpack('N2'))
        when 'PLTE'
          invalid_png! if seen['IDAT']
        when 'iCCP'
          invalid_png! if seen['PLTE'] || seen['IDAT']
          check_png_profile(payload)
        when 'IEND'
          invalid_png! unless seen['IDAT'] && payload.empty?
        end
      end

      def each_png_chunk(data)
        offset = PNG_SIGNATURE.bytesize
        while offset < data.bytesize
          invalid_png! if data.bytesize - offset < 12
          length = data.byteslice(offset, 4).unpack1('N')
          invalid_png! if length > 0x7fffffff || length > data.bytesize - offset - 12
          type = data.byteslice(offset + 4, 4)
          invalid_png! unless type.match?(%r{\A[A-Za-z]{2}[A-Z][A-Za-z]\z}n)
          payload = data.byteslice(offset + 8, length)
          crc = data.byteslice(offset + 8 + length, 4).unpack1('N')
          invalid_png! unless Zlib.crc32(payload, Zlib.crc32(type)) == crc

          yield type, payload, data.byteslice(offset, length + 12)
          offset += length + 12
          if type == 'IEND'
            invalid_png! unless offset == data.bytesize
            return
          end
        end
        invalid_png! # Missing IEND, including an incomplete final chunk.
      end

      def png_profile_data(payload)
        separator = payload.index("\0")
        invalid_png! unless separator && separator.between?(1, 79)
        name = payload.byteslice(0, separator)
        unless name.match?(%r{\A[\x20-\x7e\xa1-\xff]+\z}n) &&
               !name.start_with?(' ') && !name.end_with?(' ') && !name.include?('  ')
          invalid_png!
        end
        invalid_png! unless payload.getbyte(separator + 1)&.zero?
        compressed = payload.byteslice((separator + 2)..)
        invalid_png! if compressed.nil? || compressed.empty?
        compressed
      end

      def check_png_profile(payload)
        compressed = png_profile_data(payload)
        inflater = Zlib::Inflate.new
        expanded = 0
        offset = 0
        while offset < compressed.bytesize && !inflater.finished?
          part = compressed.byteslice(offset, 1024)
          # Block-form inflate yields small output buffers instead of allocating
          # the whole expanded profile. Never use inflate/finish without a block.
          inflater.inflate(part) do |block|
            expanded += block.bytesize
            if expanded > MAX_PNG_ICC_BYTES
              raise Error, 'Avatar PNG colour profile exceeds the 4 MiB expanded limit; re-export it with a smaller profile.'
            end
          end
          offset += part.bytesize
        end
        # Reject truncation, concatenated streams, trailing junk and empty profiles;
        # otherwise the native decoder might interpret different bytes than we did.
        invalid_png! unless inflater.finished? && inflater.total_in == compressed.bytesize && expanded.positive?
      rescue Zlib::Error
        invalid_png!
      ensure
        inflater&.close
      end

      def invalid_png!
        raise Error, 'Avatar PNG has invalid chunk structure, checksums or colour metadata; re-export it and upload it again.'
      end

      def load_backend!
        require 'image_processing/vips'
      rescue LoadError, StandardError
        raise Error, 'Avatar processing is unavailable. Ask the administrator to install image_processing, ruby-vips and libvips with PNG, JPEG, GIF and WebP support.'
      end

      def new_output
        Tempfile.new(['bible270-avatar-', '.webp'], binmode: true)
      rescue SystemCallError, IOError
        raise Error, 'Avatar output could not be created. Ask the administrator to check temporary storage.'
      end

      def write_output(data, content_type, destination)
        decoder = Vips.vips_foreign_find_load_buffer(data, data.bytesize)
        actual_type = DECODERS[decoder]
        unless actual_type
          raise Error, 'Avatar data must decode as PNG, JPEG, GIF or WebP; re-export the image and upload it again.'
        end
        unless actual_type == content_type
          raise Error, 'Avatar format does not match its content type; re-export the image and upload it again.'
        end

        check_canvas_dimensions(data, actual_type)
        options = { access: :sequential, fail_on: :warning }
        options.merge!(page: 0, n: 1) if %w[image/gif image/webp].include?(actual_type)
        image = Vips::Image.new_from_buffer(data, '', **options)
        check_dimensions(image.width, image.height)

        # libvips is lazy: materialize the entire selected frame so corruption
        # outside the eventual crop is not silently accepted.
        # ruby-vips 2.3's copy_memory wraps NULL without checking it on decode
        # failure. Check the native result before constructing/using an Image.
        decoded = Vips.vips_image_copy_memory(image)
        raise Vips::Error if decoded.null?

        image = Vips::Image.new(decoded).autorot
        image = image.icc_transform('srgb', embedded: true) if image.get_typeof('icc-profile-data').positive?
        image = image.colourspace(:srgb)
        # Page-height survives first-frame loading; do not let the saver interpret
        # the resized image as a new animation. Remaining metadata is stripped on
        # save, after orientation and embedded-profile conversion have been applied.
        image.remove('page-height')
        ImageProcessing::Vips.source(image)
          .resize_to_fill(SIZE, SIZE, sharpen: false)
          .convert('webp')
          .saver(quality: 85, strip: true)
          .call(destination: destination)
      rescue Error
        raise
      rescue StandardError
        # Native errors can contain private paths and uploaded metadata. Never
        # expose them, and keep this rescue outside the caller's block.
        raise Error, 'Avatar could not be decoded or converted. Re-export a valid PNG, JPEG, GIF or WebP; if this persists, ask the administrator to check libvips codec and colour-profile support.'
      end

      def check_dimensions(width, height)
        return if width.positive? && height.positive? && width * height <= MAX_PIXELS

        raise Error, "Avatar exceeds the #{MAX_PIXELS / 1_000_000}-megapixel limit; resize it before uploading."
      end

      def check_canvas_dimensions(data, type)
        # Check container canvases as well as the decoder's frame dimensions.
        # GIF decoders may ignore an oversized logical screen, while WebP may
        # reject a canvas/frame mismatch before exposing its header dimensions.
        if type == 'image/gif' && data.bytesize >= 10
          check_dimensions(*data.byteslice(6, 4).unpack('v2'))
        elsif type == 'image/webp' && data.bytesize >= 30 && data.byteslice(12, 4) == 'VP8X'
          width = "#{data.byteslice(24, 3)}\0".unpack1('V') + 1
          height = "#{data.byteslice(27, 3)}\0".unpack1('V') + 1
          check_dimensions(width, height)
        end
      end
    end
  end
end
