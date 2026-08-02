# frozen_string_literal: true

require 'test_helper'
require 'bible270/favicon'

class FaviconTest < Minitest::Test
  F = Bible270::Favicon

  def test_it_is_an_svg_data_uri
    assert F.data_uri.start_with?('data:image/svg+xml,')
  end

  # A raw '#' would truncate the URI at the fragment, and raw spaces are invalid
  # in one — both would leave the icon silently broken.
  def test_the_uri_contains_no_characters_that_would_break_it
    refute_includes F.data_uri, '#'
    refute_includes F.data_uri, ' '
    refute_includes F.data_uri, "\n"
  end

  # Checked without an XML parser on purpose: REXML is no longer a default gem in
  # Ruby 4.0, and the gem deliberately avoids depending on anything that has been
  # moved out of the standard library (the same reason it avoids cgi).
  def test_it_decodes_back_to_well_formed_svg
    require 'uri'
    payload = URI.decode_www_form_component(F.data_uri.sub('data:image/svg+xml,', ''))

    assert payload.start_with?('<svg'), 'should decode to an svg element'
    assert payload.strip.end_with?('</svg>'), 'should be closed'
    assert_includes payload, "xmlns='http://www.w3.org/2000/svg'"
    assert_includes payload, "viewBox='0 0 32 32'"
  end

  def test_every_element_is_closed
    require 'uri'
    payload = URI.decode_www_form_component(F.data_uri.sub('data:image/svg+xml,', ''))

    # Self-closing tags (<path ... />) need no partner; everything else does.
    opened = payload.scan(%r{<([a-z]+)\b[^>]*?(?<!/)>}).flatten
    closed = payload.scan(%r{</([a-z]+)>}).flatten

    assert_equal opened.sort, closed.sort, 'every non-self-closing element should be closed'
  end

  def test_it_stays_small_enough_to_inline_on_every_page
    assert F.data_uri.length < 1500, "favicon is #{F.data_uri.length} chars"
  end

  def test_the_source_uses_the_engine_palette
    %w[231f18 c6a24a ece6da].each do |colour|
      assert_includes F::SVG, colour, "expected the palette colour #{colour}"
    end
  end
end
