# frozen_string_literal: true

module Bible270
  # A favicon for the engine's own pages, inlined as a data URI.
  #
  # Inlined rather than served as an asset because the engine deliberately has no
  # asset-pipeline dependency — its CSS is inlined the same way — so this works
  # whether the host uses Propshaft, Sprockets or neither, and costs no request.
  module Favicon
    # A rustic loaf: a domed round on an ink board, with three slashed scores
    # across the crust and a paler crumb showing at the base.
    # Colours match the engine's palette (--ink, --gold, --paper).
    SVG = <<~SVG
      <svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'>
        <rect width='32' height='32' rx='7' fill='%23231f18'/>
        <path d='M4.5 21c0-6.2 5.1-10.5 11.5-10.5S27.5 14.8 27.5 21c0 1.4-1 2.4-2.4 2.4H6.9C5.5 23.4 4.5 22.4 4.5 21z'
              fill='%23c6a24a'/>
        <path d='M6.9 23.4h18.2c1.1 0 2-.6 2.3-1.5H4.6c.3.9 1.2 1.5 2.3 1.5z' fill='%23ece6da'/>
        <g stroke='%23231f18' stroke-width='1.6' stroke-linecap='round' opacity='.75'>
          <path d='M10.6 17.6l2.6-3'/>
          <path d='M15 16.8l2.6-3'/>
          <path d='M19.4 17.6l2.6-3'/>
        </g>
      </svg>
    SVG

  module_function

    # Percent-encoding matters here: a raw '#' would truncate the URI at the
    # fragment, and raw spaces are invalid in one.
    def data_uri
      compact = SVG.gsub(%r{\s+}, ' ').strip
      "data:image/svg+xml,#{compact.gsub(' ', '%20')}"
    end
  end
end
