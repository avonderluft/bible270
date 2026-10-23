# frozen_string_literal: true

require 'test_helper'
require 'bible270/avatar_optimizer'
# Deliberately not rescued/skipped: CI and local test runs need working codecs.
require 'image_processing/vips'
require 'open3'
require 'zlib'

class AvatarOptimizerTest < Minitest::Test
  O = Bible270::AvatarOptimizer
  RED = [230, 25, 25].freeze
  GREEN = [25, 210, 40].freeze
  BLUE = [20, 35, 230].freeze

  def setup
    @directory = Dir.mktmpdir('avatar-optimizer-test-')
    @previous_limit = Bible270.config.avatar_max_bytes
  end

  def teardown
    Bible270.config.avatar_max_bytes = @previous_limit
    FileUtils.remove_entry(@directory)
  end

  def test_version_and_resource_contract
    assert_equal '1', O::VERSION
    assert_equal 256, O::SIZE
    assert_equal 40_000_000, O::MAX_PIXELS
  end

  def test_all_four_actual_formats_produce_static_srgb_webp_without_changing_originals
    %w[png jpeg gif webp].each do |format|
      path = fixture(solid(40, 30, GREEN), format)
      original = File.binread(path)
      result = optimize(path, "image/#{format}") do |file|
        assert_instance_of Tempfile, file
        refute file.closed?
        assert_equal 0, file.pos
        assert_equal 'RIFF', file.read(4)
        image = Vips::Image.new_from_file(file.path)
        assert_equal [256, 256], [image.width, image.height]
        assert_equal :srgb, image.interpretation
        assert_equal 'webpload', image.get('vips-loader')
        assert_equal 0, image.get_typeof('n-pages')
        assert_pixel GREEN, image, 128, 128
        :block_result
      end
      assert_equal :block_result, result
      assert_equal original, File.binread(path)
    end
  end

  def test_webp_encoding_uses_quality_85
    image = Vips::Image.xyz(256, 256).bandjoin(100).cast(:uchar).copy(interpretation: :srgb)
    expected = image.webpsave_buffer(Q: 85, strip: true)
    refute_equal expected, image.webpsave_buffer(Q: 100, strip: true)
    optimize(fixture(image), 'image/png') do |file|
      assert_equal expected, file.read
    end
  end

  def test_gif_transparency_survives
    image = solid(64, 64, [0, 0, 0, 0]).insert(solid(32, 64, [*GREEN, 255]), 32, 0)
    optimize(fixture(image, 'gif'), 'image/gif') do |file|
      output = Vips::Image.new_from_file(file.path)
      assert output.has_alpha?
      assert_equal 0, output.getpoint(32, 128).last
      assert_equal 255, output.getpoint(224, 128).last
      assert_pixel GREEN, output, 224, 128
    end
  end

  def test_invalid_embedded_profile_falls_back_to_srgb_and_is_stripped
    # The JPEG saver discards invalid profiles, so insert a real APP2 segment.
    bytes = solid(20, 20, GREEN).jpegsave_buffer(strip: true)
    profile = "ICC_PROFILE\0\x01\x01private invalid profile".b
    bytes.insert(2, "\xff\xe2".b + [profile.bytesize + 2].pack('n') + profile)
    path = write_bytes(bytes, 'invalid-profile.jpeg')
    input = Vips::Image.new_from_file(path)
    assert_operator input.get_typeof('icc-profile-data'), :>, 0
    # libvips treats a corrupt ICC profile as untagged rather than failing the
    # valid pixel data. Verify that this fallback still produces safe sRGB output.
    optimize(path, 'image/jpeg') do |file|
      output = Vips::Image.new_from_file(file.path)
      assert_equal :srgb, output.interpretation
      assert_pixel GREEN, output, 128, 128
      assert_stripped output, file
      refute_includes File.binread(file.path), 'private invalid profile'
    end
  end

  def test_png_compressed_text_amplification_is_removed_before_native_loading
    original = solid(1, 1, GREEN).pngsave_buffer(strip: true)
    compressed = deflate_repeated_bytes(256 * 1024)
    # 32 small chunks represent 8 MiB of expanded text; never allocate that text.
    chunks = 32.times.map { |n| png_chunk('zTXt', "text#{n}\0\0".b + compressed) }.join
    bytes = original.dup.insert(33, chunks)
    assert_operator bytes.bytesize, :<, 16 * 1024
    path = write_bytes(bytes, 'text-amplification.png')
    loader = Vips::Image.method(:new_from_buffer)
    calls = 0
    inspect_input = ->(data, *args, **options) do
      calls += 1
      assert_equal original, data
      loader.call(data, *args, **options)
    end
    # Text must be discarded, not inflated even with a per-chunk limit.
    Zlib::Inflate.stub(:new, -> { flunk 'text must never be inflated' }) do
      Vips::Image.stub(:new_from_buffer, inspect_input) do
        optimize(path, 'image/png') do |file|
          assert_pixel GREEN, Vips::Image.new_from_file(file.path), 128, 128
          assert_stripped Vips::Image.new_from_file(file.path), file
        end
      end
    end
    assert_equal 1, calls
    assert_equal bytes, File.binread(path)
  end

  def test_png_all_text_chunk_types_are_stripped_even_after_image_data
    original = solid(1, 1, GREEN).pngsave_buffer(strip: true)
    chunks = png_chunk('tEXt', "Comment\0private".b) +
             png_chunk('iTXt', "Comment\0\0\0en\0Comment\0private".b) +
             png_chunk('iTXt', "Comment\0\x01\0en\0Comment\0".b + deflate_repeated_bytes(256 * 1024))
    bytes = original.dup.insert(original.bytesize - 12, chunks)
    path = write_bytes(bytes, 'international-text.png')
    loader = Vips::Image.method(:new_from_buffer)
    inspect_input = ->(data, *args, **options) do
      assert_equal original, data
      loader.call(data, *args, **options)
    end
    Zlib::Inflate.stub(:new, -> { flunk 'text must never be inflated' }) do
      Vips::Image.stub(:new_from_buffer, inspect_input) do
        assert_equal :ok, optimize(path, 'image/png') { :ok }
      end
    end
  end

  def test_png_exif_and_icc_survive_sanitization_and_are_applied_before_output_stripping
    image = solid(80, 80, BLUE).insert(solid(80, 40, RED), 0, 0)
      .icc_transform('srgb', input_profile: 'srgb')
    image.set_type(GObject::GINT_TYPE, 'orientation', 6)
    original = image.pngsave_buffer
    assert_includes original, 'iCCP'
    assert_includes original, 'eXIf'
    bytes = original.dup.insert(33, png_chunk('zTXt', "Comment\0\0".b + deflate_repeated_bytes(256 * 1024)))
    path = write_bytes(bytes, 'oriented-profile.png')
    loader = Vips::Image.method(:new_from_buffer)
    inspect_input = ->(data, *args, **options) do
      assert_equal original, data
      loader.call(data, *args, **options)
    end
    Vips::Image.stub(:new_from_buffer, inspect_input) do
      optimize(path, 'image/png') do |file|
        output = Vips::Image.new_from_file(file.path)
        assert_pixel BLUE, output, 32, 128
        assert_pixel RED, output, 224, 128
        assert_equal :srgb, output.interpretation
        assert_stripped output, file
      end
    end
  end

  def test_png_dimensions_are_checked_before_metadata_inflation
    bytes = png_with_chunks(png_chunk('iCCP', "Profile\0\0".b + Zlib::Deflate.deflate('profile')))
    bytes[16, 8] = [7000, 7000].pack('N2')
    bytes[29, 4] = [Zlib.crc32(bytes.byteslice(12, 17))].pack('N')
    Zlib::Inflate.stub(:new, -> { flunk 'check dimensions before inflating profiles' }) do
      assert_png_rejected_before_native bytes, %r{40-megapixel limit}
    end
  end

  def test_png_oversized_icc_is_rejected_before_native_loading
    assert_equal 4 * 1024 * 1024, O::MAX_PNG_ICC_BYTES
    profile = "Profile\0\0".b + deflate_repeated_bytes(O::MAX_PNG_ICC_BYTES + 1)
    bytes = png_with_chunks(png_chunk('iCCP', profile))
    assert_operator bytes.bytesize, :<, 16 * 1024
    assert_png_rejected_before_native bytes, %r{4 MiB expanded limit}
  end

  def test_png_icc_limit_is_inclusive_and_inflation_is_bounded
    profile = "Profile\0\0".b + deflate_repeated_bytes(O::MAX_PNG_ICC_BYTES)
    bytes = png_with_chunks(png_chunk('iCCP', profile))
    # Only test the decompression gate here: this synthetic profile is not ICC.
    assert_equal bytes, O.send(:sanitize_png, bytes)

    inflater = Zlib::Inflate.new
    original_close = inflater.method(:close)
    expanded = nil
    record_expansion = -> do
      expanded = inflater.total_out
      original_close.call
    end
    profile = "Profile\0\0".b + deflate_repeated_bytes(O::MAX_PNG_ICC_BYTES * 2)
    bytes = png_with_chunks(png_chunk('iCCP', profile))
    inflater.stub(:close, record_expansion) do
      Zlib::Inflate.stub(:new, inflater) do
        assert_png_rejected_before_native bytes, %r{4 MiB expanded limit}
      end
    end
    assert inflater.closed?
    assert_operator expanded, :>, O::MAX_PNG_ICC_BYTES
    assert_operator expanded, :<=, O::MAX_PNG_ICC_BYTES + (16 * 1024)
  end

  def test_png_duplicate_profiles_cannot_multiply_the_expansion_budget
    # Each chunk fits alone, but together they exceed the aggregate allowance.
    compressed = deflate_repeated_bytes((O::MAX_PNG_ICC_BYTES / 2) + 1)
    chunks = png_chunk('iCCP', "First\0\0".b + compressed) +
             png_chunk('iCCP', "Second\0\0".b + compressed)
    bytes = png_with_chunks(chunks)
    constructor = Zlib::Inflate.method(:new)
    calls = 0
    counted = -> do
      calls += 1
      constructor.call
    end
    Zlib::Inflate.stub(:new, counted) { assert_png_rejected_before_native bytes }
    assert_equal 1, calls, 'reject duplicate profiles before inflating another one'
  end

  def test_png_icc_names_and_compression_method_are_validated
    compressed = Zlib::Deflate.deflate('profile')
    ['', 'x' * 80, ' leading', 'trailing ', 'two  spaces', "control\x1f", "del\x7f", "invalid\x80".b].each do |name|
      assert_png_rejected_before_native png_with_chunks(png_chunk('iCCP', "#{name}\0\0".b + compressed))
    end
    ['unterminated', "name\0", "name\0\x01".b + compressed, "name\0\0"].each do |payload|
      assert_png_rejected_before_native png_with_chunks(png_chunk('iCCP', payload))
    end
    # PNG profile names use printable Latin-1, not just ASCII or UTF-8.
    profile = "caf\xe9\0\0".b + compressed
    bytes = png_with_chunks(png_chunk('iCCP', profile))
    assert_equal bytes, O.send(:sanitize_png, bytes)
  end

  def test_png_icc_rejects_bad_truncated_or_concatenated_zlib_streams
    compressed = Zlib::Deflate.deflate('profile')
    bad_checksum = compressed.dup
    bad_checksum.setbyte(-1, bad_checksum.getbyte(-1) ^ 1)
    streams = ['not zlib', compressed.byteslice(0, compressed.bytesize - 1), bad_checksum,
               compressed + compressed, "#{compressed}junk", Zlib::Deflate.deflate('')]
    streams.each do |stream|
      assert_png_rejected_before_native png_with_chunks(png_chunk('iCCP', "Profile\0\0".b + stream))
    end
  end

  def test_png_validates_crc_even_for_metadata_that_will_be_discarded
    %w[tEXt zTXt iTXt iCCP].each do |type|
      chunk = png_chunk(type, "Comment\0\0".b + Zlib::Deflate.deflate('private'))
      chunk.setbyte(-1, chunk.getbyte(-1) ^ 1)
      bytes = png_with_chunks(chunk)
      Zlib::Inflate.stub(:new, -> { flunk 'CRC must be checked before inflation' }) do
        assert_png_rejected_before_native bytes
      end
    end
  end

  def test_png_rejects_malformed_container_instead_of_repairing_it
    original = solid(1, 1, GREEN).pngsave_buffer(strip: true)
    bad_idat_crc = original.dup
    idat = bad_idat_crc.index('IDAT')
    length = bad_idat_crc.byteslice(idat - 4, 4).unpack1('N')
    bad_idat_crc.setbyte(idat + 4 + length, bad_idat_crc.getbyte(idat + 4 + length) ^ 1)
    malformed = [
      original.byteslice(0, original.bytesize - 1), # truncated checksum
      original.byteslice(0, original.bytesize - 12), # missing IEND
      "#{original}trailing bytes",
      png_with_chunks("#{[0x80000000].pack('N')}tEXt"),
      png_with_chunks("#{[100_000].pack('N')}tEXt"),
      png_with_chunks(png_chunk('texT', 'reserved bit')),
      png_with_chunks(png_chunk('t3Xt', 'invalid type')),
      png_with_chunks(original.byteslice(8, 25)), # duplicate IHDR
      original.byteslice(0, 8) + original.byteslice(33..), # missing IHDR
      original.byteslice(0, 33) + png_chunk('IEND', ''), # missing IDAT
      original.byteslice(0, original.bytesize - 12) + png_chunk('IEND', 'not empty'),
      bad_idat_crc
    ]
    malformed.each { |bytes| assert_png_rejected_before_native bytes }
  end

  def test_png_rejects_misplaced_profiles_and_duplicate_exif
    original = solid(1, 1, GREEN).pngsave_buffer(strip: true)
    profile = png_chunk('iCCP', "Profile\0\0".b + Zlib::Deflate.deflate('profile'))
    assert_png_rejected_before_native original.dup.insert(original.bytesize - 12, profile)
    assert_png_rejected_before_native png_with_chunks(png_chunk('PLTE', "\0\0\0") + profile)
    assert_png_rejected_before_native png_with_chunks(png_chunk('eXIf', 'exif') * 2)
  end

  def test_centered_landscape_crop_discards_both_edges
    image = solid(768, 384, RED).insert(solid(384, 384, GREEN), 192, 0)
    assert_green_crop image
  end

  def test_centered_portrait_crop_discards_both_edges
    image = solid(384, 768, BLUE).insert(solid(384, 384, GREEN), 0, 192)
    assert_green_crop image
  end

  def test_small_images_are_upscaled_to_exact_size
    optimize(fixture(solid(3, 5, BLUE)), 'image/png') do |file|
      image = Vips::Image.new_from_file(file.path)
      assert_equal [256, 256], [image.width, image.height]
      assert_pixel BLUE, image, 128, 128
    end
  end

  def test_exif_rotation_is_applied_before_metadata_is_stripped
    image = solid(80, 80, BLUE).insert(solid(80, 40, RED), 0, 0)
    image.set_type(GObject::GINT_TYPE, 'orientation', 6)
    image.set_type(GObject::GSTR_TYPE, 'exif-ifd0-Artist', 'Private photographer')
    path = fixture(image, 'jpeg')
    assert_equal 6, Vips::Image.new_from_file(path).get('orientation')

    optimize(path, 'image/jpeg') do |file|
      output = Vips::Image.new_from_file(file.path)
      assert_pixel BLUE, output, 32, 128
      assert_pixel RED, output, 224, 128
      assert_stripped output, file
    end
  end

  def test_mirrored_exif_orientation_is_applied
    image = solid(80, 80, BLUE).insert(solid(40, 80, RED), 0, 0)
    image.set_type(GObject::GINT_TYPE, 'orientation', 2)
    optimize(fixture(image, 'jpeg'), 'image/jpeg') do |file|
      output = Vips::Image.new_from_file(file.path)
      assert_pixel BLUE, output, 32, 128
      assert_pixel RED, output, 224, 128
    end
  end

  def test_embedded_cmyk_profile_is_converted_before_stripping
    colour = [200, 60, 30]
    image = solid(48, 48, colour).icc_transform('cmyk', input_profile: 'srgb')
    image.set_type(GObject::GSTR_TYPE, 'exif-ifd0-Artist', 'Private photographer')
    image.set_type(Vips::BLOB_TYPE, 'xmp-data', '<private>location</private>')
    path = fixture(image, 'jpeg')
    input = Vips::Image.new_from_file(path)
    assert_equal :cmyk, input.interpretation
    assert_operator input.get_typeof('icc-profile-data'), :>, 0
    assert_operator input.get_typeof('xmp-data'), :>, 0

    optimize(path, 'image/jpeg') do |file|
      output = Vips::Image.new_from_file(file.path)
      assert_equal :srgb, output.interpretation
      assert_equal 3, output.bands
      assert_pixel colour, output, 128, 128, tolerance: 18
      assert_stripped output, file
    end
  end

  def test_untagged_grayscale_and_cmyk_are_converted_to_srgb
    images = [solid(30, 30, [100]).copy(interpretation: :b_w),
              solid(30, 30, GREEN).colourspace(:cmyk)]
    images.each do |image|
      path = fixture(image, 'jpeg', strip: true)
      optimize(path, 'image/jpeg') do |file|
        output = Vips::Image.new_from_file(file.path)
        expected = Vips::Image.new_from_file(path).colourspace(:srgb).getpoint(15, 15)
        assert_equal :srgb, output.interpretation
        assert_equal 3, output.bands
        assert_pixel expected, output, 128, 128
      end
    end
  end

  def test_transparency_and_partial_alpha_survive
    image = solid(96, 96, [0, 0, 0, 0])
      .insert(solid(32, 96, [*GREEN, 128]), 32, 0)
      .insert(solid(32, 96, [*BLUE, 255]), 64, 0)
    %w[png webp].each do |format|
      optimize(fixture(image, format), "image/#{format}") do |file|
        output = Vips::Image.new_from_file(file.path)
        assert output.has_alpha?
        assert_in_delta 0, output.getpoint(20, 128).last, 1
        assert_in_delta 128, output.getpoint(128, 128).last, 1
        assert_in_delta 255, output.getpoint(230, 128).last, 1
        assert_pixel GREEN, output, 128, 128
      end
    end
  end

  def test_animated_gif_and_webp_use_only_the_first_frame
    frames = solid(40, 30, RED).join(solid(40, 30, BLUE), :vertical)
    frames.set_type(GObject::GINT_TYPE, 'page-height', 30)
    frames.set_type(Vips::ARRAY_INT_TYPE, 'delay', [100, 100])
    frames.set_type(GObject::GINT_TYPE, 'loop', 0)
    %w[gif webp].each do |format|
      path = fixture(frames, format)
      input = Vips::Image.new_from_file(path, n: -1)
      assert_equal 2, input.get('n-pages')
      assert_pixel BLUE, input, 20, 45
      optimize(path, "image/#{format}") do |file|
        output = Vips::Image.new_from_file(file.path, n: -1)
        assert_equal [256, 256], [output.width, output.height]
        assert_equal 0, output.get_typeof('n-pages')
        assert_pixel RED, output, 128, 128
        refute_includes File.binread(file.path), 'ANIM'
      end
    end
  end

  def test_normalized_content_type_and_misleading_filename
    path = fixture(solid(20, 20, GREEN), 'png', filename: 'upload.svg')
    assert_equal :ok, optimize(path, ' IMAGE/PNG; charset=binary ') { :ok }
  end

  def test_unsupported_actual_decoders_are_rejected_even_with_accepted_mime_and_extension
    paths = [write_bytes('<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>', 'svg.png'),
             fixture(solid(10, 10, GREEN), 'tiff', filename: 'tiff.png'),
             write_bytes('<html>not an image</html>', 'html.png')]
    paths.each do |path|
      error = assert_raises(O::Error) { optimize(path, 'image/png') { flunk 'must not yield' } }
      assert_match(%r{must decode as PNG, JPEG, GIF or WebP}, error.message)
    end
  end

  def test_accepted_but_mismatched_mime_is_rejected
    path = fixture(solid(20, 20, GREEN))
    error = assert_raises(O::Error) { optimize(path, 'image/jpeg') { flunk 'must not yield' } }
    assert_match(%r{does not match its content type}, error.message)
  end

  def test_invalid_declared_types_and_sizes
    path = fixture(solid(20, 20, GREEN))
    ['image/svg+xml', 'image/tiff', '', nil].each do |type|
      assert_raises(O::Error) { optimize(path, type) { flunk 'must not yield' } }
    end
    [nil, 0, -1, '100', 1.5, File.size(path) + 1, File.size(path) - 1].each do |size|
      assert_raises(O::Error) do
        O.open(path, content_type: 'image/png', byte_size: size) { flunk 'must not yield' }
      end
    end
  end

  def test_actual_and_declared_sizes_both_obey_configured_limit
    path = fixture(solid(20, 20, GREEN))
    size = File.size(path)
    Bible270.config.avatar_max_bytes = size
    assert_equal :ok, optimize(path, 'image/png') { :ok }
    Bible270.config.avatar_max_bytes = size - 1
    [size, 1].each do |declared|
      error = assert_raises(O::Error) do
        O.open(path, content_type: 'image/png', byte_size: declared) { flunk 'must not yield' }
      end
      assert_match(%r{no larger than}, error.message)
    end
    Bible270.config.avatar_max_bytes = size
    assert_raises(O::Error) do
      O.open(path, content_type: 'image/png', byte_size: size + 1) { flunk 'must not yield' }
    end
  end

  def test_changed_file_between_stat_and_read_is_rejected
    path = fixture(solid(20, 20, GREEN))
    File.stub(:binread, 'changed') do
      error = assert_raises(O::Error) { optimize(path, 'image/png') { flunk 'must not yield' } }
      assert_match(%r{changed while being read}, error.message)
    end
  end

  def test_empty_missing_and_non_file_paths_have_safe_errors
    path = write_bytes('', 'empty.png')
    [path, File.join(@directory, 'private-missing.png'), @directory].each do |input|
      error = assert_raises(O::Error) do
        O.open(input, content_type: 'image/png', byte_size: 1) { flunk 'must not yield' }
      end
      refute_includes error.message, @directory
    end
  end

  def test_corrupt_pixel_data_is_rejected_not_just_valid_headers
    image = Vips::Image.xyz(256, 256).bandjoin(100).cast(:uchar).copy(interpretation: :srgb)
    %w[png jpeg gif webp].each do |format|
      bytes = image.write_to_buffer(".#{format}")
      path = write_bytes(bytes.byteslice(0, bytes.bytesize * 2 / 3), "corrupt.#{format}")
      assert_raises(O::Error, format) { optimize(path, "image/#{format}") { flunk 'must not yield' } }
    end
  end

  def test_extreme_png_header_is_rejected_before_decoding_missing_pixels
    bytes = solid(2, 2, GREEN).pngsave_buffer
    bytes[16, 8] = [7000, 7000].pack('N2')
    bytes[29, 4] = [Zlib.crc32(bytes.byteslice(12, 17))].pack('N')
    assert_pixel_limit bytes, 'png'
  end

  def test_extreme_jpeg_header_is_rejected_before_decoding_missing_pixels
    bytes = solid(2, 2, GREEN).jpegsave_buffer
    start = bytes.index("\xff\xc0".b)
    refute_nil start
    bytes[start + 5, 4] = [7000, 7000].pack('n2')
    assert_pixel_limit bytes, 'jpeg'
  end

  def test_extreme_gif_canvas_is_rejected_before_decoding
    bytes = solid(2, 2, GREEN).gifsave_buffer
    bytes[6, 4] = [7000, 7000].pack('v2')
    assert_pixel_limit bytes, 'gif'
  end

  def test_extreme_webp_canvas_is_rejected_before_decoding
    bytes = solid(2, 2, [*GREEN, 128]).webpsave_buffer(strip: true)
    assert_equal 'VP8X', bytes.byteslice(12, 4)
    bytes[24, 6] = [6999].pack('V').byteslice(0, 3) * 2
    assert_pixel_limit bytes, 'webp'
  end

  def test_output_is_closed_and_unlinked_after_success
    captured = nil
    path = nil
    optimize(fixture(solid(10, 10, GREEN)), 'image/png') do |file|
      captured = file
      path = file.path
      assert File.exist?(path)
    end
    assert captured.closed?
    refute File.exist?(path)
  end

  def test_caller_exceptions_are_not_wrapped_and_output_is_always_cleaned
    input = fixture(solid(10, 10, GREEN))
    [RuntimeError.new('caller failure'), Vips::Error.new('caller vips failure'), LoadError.new('caller load failure')].each do |failure|
      captured = nil
      path = nil
      raised = assert_raises(failure.class) do
        optimize(input, 'image/png') do |file|
          captured = file
          path = file.path
          raise failure
        end
      end
      assert_same failure, raised
      assert captured.closed?
      refute File.exist?(path)
    end
  end

  def test_non_local_block_exit_also_cleans_output
    captured = nil
    path = nil
    result = optimize(fixture(solid(10, 10, GREEN)), 'image/png') do |file|
      captured = file
      path = file.path
      break :early_exit
    end
    assert_equal :early_exit, result
    assert captured.closed?
    refute File.exist?(path)
  end

  def test_processing_failure_removes_partial_output_and_has_a_safe_message
    input = fixture(solid(10, 10, GREEN))
    captured = nil
    path = nil
    constructor = Tempfile.method(:new)
    create = ->(*args, **kwargs) do
      captured = constructor.call(*args, **kwargs)
      path = captured.path
      captured.write('partial output')
      captured.flush
      captured
    end
    Tempfile.stub(:new, create) do
      ImageProcessing::Vips.stub(:source, ->(*) { raise Vips::Error, "secret: #{input}" }) do
        error = assert_raises(O::Error) { optimize(input, 'image/png') { flunk 'must not yield' } }
        assert_match(%r{Re-export}, error.message)
        refute_includes error.message, input
        refute_includes error.message, 'secret'
      end
    end
    assert captured.closed?
    refute File.exist?(path)
  end

  def test_missing_dependency_has_actionable_safe_error
    path = fixture(solid(10, 10, GREEN))
    O.stub(:require, ->(*) { raise LoadError, '/private/native/library.so missing' }) do
      error = assert_raises(O::Error) { optimize(path, 'image/png') { flunk 'must not yield' } }
      assert_match(%r{install image_processing, ruby-vips and libvips}, error.message)
      refute_includes error.message, '/private'
    end
  end

  def test_requiring_optimizer_alone_does_not_load_native_backend_or_rails
    script = <<~RUBY
      module Kernel
        alias original_require require
        def require(name)
          raise LoadError, 'native dependency unavailable' if %w[vips image_processing/vips].include?(name)
          original_require(name)
        end
      end
      require 'bible270/avatar_optimizer'
      abort 'native library loaded' if defined?(Vips) || defined?(ImageProcessing)
      abort 'Rails loaded' if defined?(Rails) || defined?(ActiveStorage)
      puts Bible270::AvatarOptimizer::VERSION
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-I', File.expand_path('../lib', __dir__), '-e', script)
    assert status.success?, stderr
    assert_equal "1\n", stdout
  end

private

  def png_chunk(type, payload)
    data = type.b + payload.b
    [payload.bytesize].pack('N') + data + [Zlib.crc32(data)].pack('N')
  end

  def png_with_chunks(chunks)
    solid(1, 1, GREEN).pngsave_buffer(strip: true).dup.insert(33, chunks)
  end

  def deflate_repeated_bytes(size)
    deflater = Zlib::Deflate.new
    compressed = +''.b
    block = 'x' * (16 * 1024)
    while size.positive?
      length = [size, block.bytesize].min
      compressed << deflater.deflate(block.byteslice(0, length))
      size -= length
    end
    compressed << deflater.finish
  ensure
    deflater&.close
  end

  def assert_png_rejected_before_native(bytes, message = %r{invalid chunk structure})
    path = write_bytes(bytes, 'invalid-metadata.png')
    O.stub(:load_backend!, -> { flunk 'PNG validation must precede native loading' }) do
      error = assert_raises(O::Error) { optimize(path, 'image/png') { flunk 'must not yield' } }
      assert_match message, error.message
      refute_includes error.message, path
    end
  end

  def solid(width, height, colour)
    (Vips::Image.black(width, height, bands: colour.length) + colour)
      .cast(:uchar).copy(interpretation: :srgb).copy_memory
  end

  def fixture(image, format = 'png', filename: "fixture.#{format}", **)
    write_bytes(image.write_to_buffer(".#{format}", **), filename)
  end

  def write_bytes(bytes, filename)
    @fixture_number = (@fixture_number || 0) + 1
    File.join(@directory, "#{@fixture_number}-#{filename}").tap { |path| File.binwrite(path, bytes) }
  end

  def optimize(path, type, &)
    O.open(path, content_type: type, byte_size: File.size(path), &)
  end

  def assert_pixel(expected, image, x, y, tolerance: 12)
    expected.first(3).zip(image.getpoint(x, y).first(3)).each do |wanted, actual|
      assert_in_delta wanted, actual, tolerance
    end
  end

  def assert_green_crop(image)
    optimize(fixture(image), 'image/png') do |file|
      output = Vips::Image.new_from_file(file.path)
      assert_equal [256, 256], [output.width, output.height]
      [[4, 4], [251, 4], [4, 251], [251, 251], [128, 128]].each do |x, y|
        assert_pixel GREEN, output, x, y
      end
    end
  end

  def assert_stripped(image, file)
    %w[exif-data xmp-data icc-profile-data orientation].each do |field|
      assert_equal 0, image.get_typeof(field), field
    end
    assert_empty image.get_fields.grep(%r{\Aexif-})
    refute_includes File.binread(file.path), 'Private photographer'
    refute_includes File.binread(file.path), '<private>'
  end

  def assert_pixel_limit(bytes, format)
    path = write_bytes(bytes, "extreme.#{format}")
    error = assert_raises(O::Error) { optimize(path, "image/#{format}") { flunk 'must not yield' } }
    assert_match(%r{40-megapixel limit}, error.message)
  end
end
