# frozen_string_literal: true

require 'test_helper'
require 'bible270/comment_formatter'

class CommentFormatterTest < Minitest::Test
  Formatter = Bible270::CommentFormatter
  VIDEO_ID = 'aB3_dE-fG12'
  VIDEO_URL = "https://www.youtube.com/watch?v=#{VIDEO_ID}".freeze

  def test_plain_text_stays_literal_and_keeps_line_breaks
    html = Formatter.html("**not bold**\n<script>alert(1)</script>", format: Formatter::PLAIN)

    assert_includes html, '**not bold**'
    assert_includes html, '<br>'
    assert_includes html, '&lt;script&gt;alert(1)&lt;/script&gt;'
    refute_includes html, '<strong>'
  end

  def test_markdown_supports_the_toolbar_formatting
    html = Formatter.html("**Bold** and *italic*\nnext line\n\n> Quoted\n\n- one\n- two", format: Formatter::MARKDOWN)

    assert_includes html, '<strong>Bold</strong>'
    assert_includes html, '<em>italic</em>'
    assert_match(%r{<em>italic</em><br>next line}, html)
    assert_includes html, '<blockquote>'
    assert_match(%r{<ul>.*<li>one</li>.*<li>two</li>.*</ul>}m, html)
  end

  def test_blank_lines_between_list_items_do_not_create_visible_spacing
    html = Formatter.html("- one\n\n- two\n\n1. one\n\n2. two", format: Formatter::MARKDOWN)

    assert_match(%r{<ul>\s*<li>one</li>\s*<li>two</li>\s*</ul>}m, html)
    assert_match(%r{<ol>\s*<li>one</li>\s*<li>two</li>\s*</ol>}m, html)
    refute_match(%r{<li>\s*<br}, html)
    refute_match(%r{<li>\s*<p>}, html)
  end

  def test_markdown_is_strictly_sanitized
    html = Formatter.html(
      '[safe](https://example.org) [bad](javascript:alert(1)) ' \
      '<script>alert(2)</script><img src=x onerror="alert(3)">',
      format: Formatter::MARKDOWN
    )

    assert_includes html, 'href="https://example.org"'
    assert_includes html, 'rel="nofollow ugc noopener"'
    refute_match(%r{<script\b}i, html)
    refute_match(%r{<img\b}i, html)
    refute_match(%r{onerror\s*=}i, html)
    refute_match(%r{href="javascript:}i, html)
  end

  def test_markdown_auto_links_bare_web_urls_without_swallowing_punctuation
    html = Formatter.html(
      'Read https://example.org/guide. Or use HTTP://example.org/help!',
      format: Formatter::MARKDOWN
    )

    assert_match(%r{<a href="https://example.org/guide"[^>]*>https://example.org/guide</a>\.}, html)
    assert_match(%r{<a href="HTTP://example.org/help"[^>]*>HTTP://example.org/help</a>!}, html)
    assert_equal 2, html.scan('rel="nofollow ugc noopener"').size
  end

  def test_markdown_does_not_auto_link_urls_inside_explicit_links
    html = Formatter.html('[Guide](https://example.org/guide)', format: Formatter::MARKDOWN)

    assert_equal 1, html.scan('<a ').size
    assert_match(%r{<a href="https://example.org/guide"[^>]*>Guide</a>}, html)
  end

  def test_plain_text_urls_remain_literal
    html = Formatter.html('Visit https://example.org', format: Formatter::PLAIN)

    refute_includes html, '<a '
    assert_includes html, 'https://example.org'
  end

  def test_mentions_can_be_linked_inside_formatting_but_not_inside_existing_links
    requested = []
    html = Formatter.html('**Hello @Mary** [@Mary](https://example.org)', format: Formatter::MARKDOWN) do |handle|
      requested << handle
      '/readers/1'
    end

    assert_match(%r{<strong>Hello <a href="/readers/1" class="b270-mention"[^>]*>@Mary</a></strong>}, html)
    assert_match(%r{<a href="https://example.org"[^>]*>@Mary</a>}, html)
    assert_equal ['mary'], requested
    refute_match(%r{<a[^>]*><a}, html)
  end

  def test_video_cards_require_explicit_opt_in_and_markdown
    source = video_marker
    default_html = Formatter.html(source, format: Formatter::MARKDOWN)
    disabled_html = Formatter.html(source, format: Formatter::MARKDOWN, embed_videos: false)

    assert_equal default_html, disabled_html
    fragment = Nokogiri::HTML.fragment(default_html)
    assert_empty fragment.css('.b270-video, button, [title]')
    assert_equal VIDEO_URL, fragment.at_css('p > a')['href']
    assert_equal 'YouTube video', fragment.at_css('a').text
    assert_equal Formatter::LINK_REL, fragment.at_css('a')['rel']

    plain_html = Formatter.html(source, embed_videos: true)
    assert_empty Nokogiri::HTML.fragment(plain_html).css('a, .b270-video, button')
    assert_includes plain_html, 'bible270-video'
  end

  def test_video_card_contract_and_canonical_fallback
    source = video_marker("http://youtu.be/#{VIDEO_ID}?autoplay=1&si=tracking#t=30")
    fragment = video_fragment(source)
    card = fragment.at_css('div.b270-video')

    refute_nil card
    assert_equal VIDEO_ID, card['data-b270-video-id']
    assert_equal 1, fragment.css('.b270-video').size
    button = card.at_css('button[data-b270-video-load]')
    assert_equal 'button', button['type']
    assert button.key?('hidden')
    assert_equal 'View video', button.text
    assert_equal 'Loads player and shares data with YouTube', button['title']
    assert_empty card.css('p')
    refute_includes card.text, 'shares data with YouTube'
    link = card.at_css('a')
    assert_equal VIDEO_URL, link['href']
    assert_equal 'Open on YouTube', link.text
    assert_equal Formatter::LINK_REL, link['rel']
    assert_equal '_blank', link['target']
    assert_equal 'Opens YouTube in a new tab.', link['title']
    assert_empty fragment.css('p .b270-video')
    assert_empty fragment.css('iframe, img, picture, source, video, audio, object, embed, script, link, style, [src], [srcset], [style]')
    refute_includes fragment.to_html, 'autoplay'
    refute_includes fragment.to_html, 'tracking'
    refute_includes fragment.to_html, 'youtube-nocookie.com'
  end

  def test_named_video_buttons_are_plain_text_and_names_survive_email_fallbacks
    name = 'Grace [today] & <hope> *now* \\ @Mary https://example.org'
    encoded = 'Grace &#91;today&#93; &#38; &#60;hope&#62; &#42;now&#42; &#92; &#64;Mary https&#58;&#47;&#47;example&#46;org'
    source = "[#{encoded}](#{VIDEO_URL} \"bible270-video\")"
    html = Formatter.html(source, format: Formatter::MARKDOWN, embed_videos: true) { '/readers/1' }
    button = Nokogiri::HTML.fragment(html).at_css('button')

    assert_equal "View video ‘#{name}’", button.text
    assert_empty button.element_children
    email = Nokogiri::HTML.fragment(Formatter.html(source, format: Formatter::MARKDOWN))
    assert_equal name, email.at_css('a').text
    assert_empty email.css('button, [title], [target]')
    assert_equal "#{name} (#{VIDEO_URL})", Formatter.text(source, format: Formatter::MARKDOWN)
  end

  def test_supported_youtube_hosts_schemes_and_paths
    %w[http https].each do |scheme|
      %w[youtube.com www.youtube.com m.youtube.com].each do |host|
        ["watch?v=#{VIDEO_ID}", "shorts/#{VIDEO_ID}", "live/#{VIDEO_ID}", "embed/#{VIDEO_ID}"].each do |path|
          url = "#{scheme}://#{host}/#{path}"
          card = video_fragment(video_marker(url)).at_css('.b270-video')
          refute_nil card, url
          assert_equal VIDEO_ID, card['data-b270-video-id'], url
        end
      end
      %w[youtu.be www.youtu.be].each do |host|
        url = "#{scheme}://#{host}/#{VIDEO_ID}"
        assert_equal VIDEO_ID, video_fragment(video_marker(url)).at_css('.b270-video')['data-b270-video-id'], url
      end
    end
  end

  def test_supported_urls_ignore_other_parameters_and_accept_standard_ports
    [
      "https://WWW.YouTube.COM:443/watch?feature=share&v=#{VIDEO_ID}&t=42#chapter",
      "http://youtube.com:80/watch?v=#{VIDEO_ID}",
      "https://youtu.be:443/#{VIDEO_ID}?si=tracking",
      "https://youtube.com/live/#{VIDEO_ID}?feature=share"
    ].each do |url|
      fragment = video_fragment(video_marker(url))
      assert_equal VIDEO_ID, fragment.at_css('.b270-video')['data-b270-video-id'], url
      assert_equal VIDEO_URL, fragment.at_css('a')['href'], url
    end
  end

  def test_ordinary_youtube_links_never_embed
    [
      "[YouTube video](#{VIDEO_URL})",
      "[YouTube video](#{VIDEO_URL} \"Some other title\")",
      "[YouTube video](#{VIDEO_URL} \"bible270-video-extra\")",
      VIDEO_URL,
      "<#{VIDEO_URL}>"
    ].each do |source|
      fragment = video_fragment(source)
      assert_empty fragment.css('.b270-video, button, [title]'), source
      assert_equal VIDEO_URL, fragment.at_css('a')['href'], source
    end
  end

  def test_video_markers_must_be_the_only_content_of_a_paragraph
    [
      "Before #{video_marker}",
      "#{video_marker} after",
      "#{video_marker}\nNext line",
      "#{video_marker} #{video_marker}",
      "**#{video_marker}**",
      "- #{video_marker}"
    ].each do |source|
      fragment = video_fragment(source)
      assert_empty fragment.css('.b270-video, button, [title]'), source
      assert_equal VIDEO_URL, fragment.at_css('a')['href'], source
    end
  end

  def test_standalone_video_marker_replaces_its_paragraph_without_disturbing_other_content
    fragment = video_fragment("Before\n\n#{video_marker}\n\nAfter\n\n> #{video_marker}")

    assert_equal %w[p div p blockquote], fragment.element_children.map(&:name)
    assert_equal 'Before', fragment.element_children.first.text
    assert_equal 'After', fragment.element_children[2].text
    assert_equal 2, fragment.css('.b270-video').size
    assert_equal 1, fragment.css('blockquote > .b270-video').size
    assert_empty fragment.css('p .b270-video')
  end

  def test_host_spoofing_credentials_and_odd_ports_remain_links
    [
      "https://youtube.com.evil.example/watch?v=#{VIDEO_ID}",
      "https://evil-youtube.com/watch?v=#{VIDEO_ID}",
      "https://notyoutube.com/watch?v=#{VIDEO_ID}",
      "https://www.youtu.be.evil.example/#{VIDEO_ID}",
      "https://music.youtube.com/watch?v=#{VIDEO_ID}",
      "https://youtube.com./watch?v=#{VIDEO_ID}",
      "https://youtube-nocookie.com/embed/#{VIDEO_ID}",
      "https://youtube.com@evil.example/watch?v=#{VIDEO_ID}",
      "https://evil.example@youtube.com/watch?v=#{VIDEO_ID}",
      "https://user:password@youtube.com/watch?v=#{VIDEO_ID}",
      "https://@youtube.com/watch?v=#{VIDEO_ID}",
      "https://youtube.com:444/watch?v=#{VIDEO_ID}",
      "https://youtube.com:80/watch?v=#{VIDEO_ID}",
      "http://youtube.com:443/watch?v=#{VIDEO_ID}",
      "https://youtube.com:/watch?v=#{VIDEO_ID}",
      "https://youtube.com:0443/watch?v=#{VIDEO_ID}",
      "//youtube.com/watch?v=#{VIDEO_ID}",
      "ftp://youtube.com/watch?v=#{VIDEO_ID}"
    ].each do |url|
      assert_nil Bible270::YouTubeVideo.id_from_url(url), url
      fragment = video_fragment(video_marker(url))
      assert_empty fragment.css('.b270-video, button, [title]'), url
      assert_equal url, fragment.at_css('a')['href'], url
    end
  end

  def test_malformed_ids_and_unsupported_paths_remain_links
    [
      'https://youtube.com/watch',
      'https://youtube.com/watch?v=',
      'https://youtube.com/watch?v=too_short',
      "https://youtube.com/watch?v=#{VIDEO_ID}x",
      'https://youtube.com/watch?v=aB3.dE-fG12',
      'https://youtube.com/watch?v=aB3+dE-fG12',
      'https://youtube.com/watch?v=aB3%2FdE-fG1',
      "https://youtube.com/watch?v=#{VIDEO_ID}%0A",
      "https://youtube.com/watch?v=#{VIDEO_ID}&v=#{VIDEO_ID}",
      "https://youtube.com/playlist?list=#{VIDEO_ID}",
      "https://youtube.com/watch/?v=#{VIDEO_ID}",
      "https://youtube.com/shorts/#{VIDEO_ID}/extra",
      "https://youtube.com/embed/#{VIDEO_ID}/",
      "https://youtube.com/live/#{VIDEO_ID}x",
      "https://youtube.com/#{VIDEO_ID}",
      "https://youtu.be/watch?v=#{VIDEO_ID}",
      "https://youtu.be/#{VIDEO_ID}/extra",
      "https://youtu.be/#{VIDEO_ID}/",
      'https://youtu.be/too_short'
    ].each do |url|
      fragment = video_fragment(video_marker(url))
      assert_empty fragment.css('.b270-video, button, [title]'), url
      assert_equal url, fragment.at_css('a')['href'], url
    end
  end

  def test_malformed_urls_are_rejected_without_raising
    [
      '', 'not a URL', 'https://',
      "https:///youtube.com/watch?v=#{VIDEO_ID}",
      "https://youtube.com:invalid/watch?v=#{VIDEO_ID}",
      "https://youtube.com\\@evil.example/watch?v=#{VIDEO_ID}",
      "https://youtube.com/watch?v=#{VIDEO_ID}\n",
      "https://youtube.com/watch?v=#{VIDEO_ID}&bad=%ZZ",
      "https://youtube.com/watch?v=#{VIDEO_ID}&bad=%",
      "https://youtube.com/watch?v=#{VIDEO_ID}\u0000",
      "javascript:alert('#{VIDEO_ID}')",
      "data:text/html,#{VIDEO_ID}"
    ].each do |url|
      assert_nil Bible270::YouTubeVideo.id_from_url(url), url
    end
  end

  def test_raw_iframes_and_forged_card_html_are_not_allowed
    source = <<~HTML
      <iframe src="https://www.youtube.com/embed/#{VIDEO_ID}" allowfullscreen></iframe>
      <iframe srcdoc="&lt;script&gt;alert(1)&lt;/script&gt;"></iframe>
      <div class="b270-video" data-b270-video-id="#{VIDEO_ID}">
        <button type="button" data-b270-video-load onclick="alert(1)">Load video</button>
        <img src="https://i.ytimg.com/vi/#{VIDEO_ID}/default.jpg">
      </div>

      #{video_marker}
    HTML
    fragment = video_fragment(source)

    assert_equal 1, fragment.css('.b270-video').size
    assert_equal 1, fragment.css('button').size
    assert_empty fragment.css('iframe, img, script, object, embed, [src], [srcdoc], [onclick]')
    assert_equal 1, fragment.css('[data-b270-video-id], [class]').size
  end

  def test_unsafe_marked_links_are_sanitized_even_with_video_opt_in
    fragment = video_fragment('[YouTube video](javascript:alert(1) "bible270-video")')

    assert_empty fragment.css('.b270-video, button, a, [title]')
    assert_includes fragment.text, 'YouTube video'
  end

  def test_video_markers_have_a_readable_text_fallback
    assert_equal "YouTube video (#{VIDEO_URL})", Formatter.text(video_marker, format: Formatter::MARKDOWN)

    short_url = "https://youtu.be/#{VIDEO_ID}?t=42"
    assert_equal "Before\n\nYouTube video (#{short_url})\n\nAfter",
                 Formatter.text("Before\n\n#{video_marker(short_url)}\n\nAfter", format: Formatter::MARKDOWN)
    assert_equal video_marker, Formatter.text(video_marker)
  end

  def test_markdown_has_a_readable_plain_text_version_for_email
    text = Formatter.text("**Bold**\n\n- one\n- two\n\n[Source](https://example.org)", format: Formatter::MARKDOWN)

    assert_equal "Bold\n\none\n\ntwo\n\nSource (https://example.org)", text
  end

private

  def video_marker(url = VIDEO_URL)
    "[YouTube video](#{url} \"bible270-video\")"
  end

  def video_fragment(source)
    Nokogiri::HTML.fragment(Formatter.html(source, format: Formatter::MARKDOWN, embed_videos: true))
  end
end
