# frozen_string_literal: true

require 'test_helper'
require 'bible270/comment_formatter'

class CommentFormatterTest < Minitest::Test
  Formatter = Bible270::CommentFormatter

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

  def test_markdown_has_a_readable_plain_text_version_for_email
    text = Formatter.text("**Bold**\n\n- one\n- two\n\n[Source](https://example.org)", format: Formatter::MARKDOWN)

    assert_equal "Bold\n\none\n\ntwo\n\nSource (https://example.org)", text
  end
end
