# frozen_string_literal: true

require 'erb'
require 'kramdown'
require 'nokogiri'
require 'rails-html-sanitizer'
require 'bible270/mentions'
require 'bible270/youtube_video'

module Bible270
  # Converts stored reflection source into a deliberately small, safe subset of
  # HTML. Plain bodies remain literal; Markdown bodies gain only the formatting
  # exposed by the reflection toolbar.
  module CommentFormatter
    PLAIN = 'plain'
    MARKDOWN = 'markdown'
    FORMATS = [PLAIN, MARKDOWN].freeze
    ALLOWED_TAGS = %w[p br strong em blockquote ul ol li a].freeze
    ALLOWED_ATTRIBUTES = %w[href rel title].freeze
    VIDEO_MARKER = 'bible270-video'
    VIDEO_PRIVACY = 'Loads player and shares data with YouTube'
    LINK_REL = 'nofollow ugc noopener'
    URL_PATTERN = %r{https?://[^\s<>"]*[^\s<>".,;:!?)\]\}]}i
    SKIP_MENTIONS_IN = %w[a button code pre].freeze

  module_function

    def html(body, format: PLAIN, embed_videos: false, &mention_path)
      source = body.to_s
      rendered = format == MARKDOWN ? markdown_html(source) : plain_html(source)
      fragment = fragment_for(sanitize(rendered))
      if format == MARKDOWN
        replace_video_markers(fragment) if embed_videos
        normalize_lists(fragment)
        hard_wrap(fragment)
        link_urls(fragment)
      end
      fragment.css('[title]').each { |node| node.remove_attribute('title') }
      fragment.css('.b270-video button').each { |node| node['title'] = VIDEO_PRIVACY }
      fragment.css('.b270-video a').each { |node| node['title'] = 'Opens YouTube in a new tab.' }
      decorate_links(fragment)
      link_mentions(fragment, &mention_path) if mention_path
      fragment.to_html
    end

    def text(body, format: PLAIN)
      return body.to_s if format != MARKDOWN

      fragment = fragment_for(html(body, format: format))
      fragment.css('a[href]').each do |link|
        href = link['href'].to_s
        next if href.empty? || link.text == href

        link.add_next_sibling(Nokogiri::XML::Text.new(" (#{href})", fragment.document))
      end
      fragment.css('br').each do |break_node|
        break_node.replace(Nokogiri::XML::Text.new("\n", fragment.document))
      end
      fragment.css('p, blockquote, li').each do |block|
        block.add_next_sibling(Nokogiri::XML::Text.new("\n", fragment.document))
      end
      fragment.text.lines.map(&:strip).join("\n").gsub(%r{\n{3,}}, "\n\n").strip
    end

    def markdown_html(source)
      Kramdown::Document.new(source).to_html
    end
    private_class_method :markdown_html

    def plain_html(source)
      paragraphs = source.split(%r{(?:\r?\n){2,}}, -1).filter_map do |paragraph|
        next if paragraph.empty?

        escaped = ERB::Util.html_escape(paragraph).gsub(%r{\r?\n}, "<br>\n")
        "<p>#{escaped}</p>"
      end
      paragraphs.join("\n")
    end
    private_class_method :plain_html

    def sanitize(rendered)
      Rails::Html::SafeListSanitizer.new.sanitize(
        rendered,
        tags: ALLOWED_TAGS,
        attributes: ALLOWED_ATTRIBUTES
      )
    end
    private_class_method :sanitize

    def fragment_for(rendered)
      Nokogiri::HTML::DocumentFragment.parse(rendered)
    end
    private_class_method :fragment_for

    # Blank lines between Markdown list items make Kramdown wrap each item's
    # content in a paragraph. For a simple item, remove that structural wrapper
    # and its indentation so loose and compact lists render identically.
    def normalize_lists(fragment)
      fragment.xpath('.//li/text()[normalize-space(.) = ""]').remove
      fragment.css('li').each do |item|
        children = item.element_children
        next unless children.one? && children.first.name == 'p'

        children.first.replace(children.first.children)
      end
    end
    private_class_method :normalize_lists

    def hard_wrap(fragment)
      fragment.xpath('.//p//text() | .//li//text()').to_a.each do |node|
        next unless node.text.include?("\n")

        replacement = Nokogiri::HTML::DocumentFragment.parse('')
        node.text.split("\n", -1).each_with_index do |line, index|
          replacement.add_child(Nokogiri::XML::Node.new('br', fragment.document)) if index.positive?
          replacement.add_child(Nokogiri::XML::Text.new(line, fragment.document))
        end
        node.replace(replacement)
      end
    end
    private_class_method :hard_wrap

    def link_urls(fragment)
      fragment.xpath('.//text()').to_a.each do |node|
        next if node.ancestors.any? { |ancestor| SKIP_MENTIONS_IN.include?(ancestor.name) }
        next unless node.text.match?(URL_PATTERN)

        replacement = Nokogiri::HTML::DocumentFragment.parse('')
        cursor = 0
        node.text.to_enum(:scan, URL_PATTERN).each do
          match = Regexp.last_match
          replacement.add_child(Nokogiri::XML::Text.new(node.text[cursor...match.begin(0)], fragment.document))
          link = Nokogiri::XML::Node.new('a', fragment.document)
          link['href'] = match[0]
          link.content = match[0]
          replacement.add_child(link)
          cursor = match.end(0)
        end
        replacement.add_child(Nokogiri::XML::Text.new(node.text[cursor..].to_s, fragment.document))
        node.replace(replacement)
      end
    end
    private_class_method :link_urls

    def replace_video_markers(fragment)
      fragment.css('p').each do |paragraph|
        children = paragraph.children.reject { |node| node.text? && node.text.strip.empty? }
        next unless children.one?

        link = children.first
        next unless link.name == 'a' && link['title'] == VIDEO_MARKER

        id = YouTubeVideo.id_from_url(link['href'].to_s)
        paragraph.replace(video_card(id, fragment.document, name: link.text.strip)) if id
      end
    end
    private_class_method :replace_video_markers

    # These elements are generated only after sanitization; they are deliberately
    # not part of the allowlist for user-supplied HTML.
    def video_card(id, document, name:)
      card = Nokogiri::XML::Node.new('div', document)
      card['class'] = 'b270-video'
      card['data-b270-video-id'] = id

      button = Nokogiri::XML::Node.new('button', document)
      button['type'] = 'button'
      button['data-b270-video-load'] = ''
      button['hidden'] = 'hidden'
      button.content = name.empty? || name == 'YouTube video' ? 'View video' : "View video ‘#{name}’"
      card.add_child(button)

      link = Nokogiri::XML::Node.new('a', document)
      link['href'] = "https://www.youtube.com/watch?v=#{id}"
      link['target'] = '_blank'
      link.content = 'Open on YouTube'
      card.add_child(link)
      card
    end
    private_class_method :video_card

    def decorate_links(fragment)
      fragment.css('a:not([href])').each do |link|
        link.replace(Nokogiri::XML::Text.new(link.text, fragment.document))
      end
      fragment.css('a[href]').each { |link| link['rel'] = LINK_REL }
    end
    private_class_method :decorate_links

    def link_mentions(fragment)
      text_nodes = fragment.xpath('.//text()').to_a
      text_nodes.each do |node|
        next if node.ancestors.any? { |ancestor| SKIP_MENTIONS_IN.include?(ancestor.name) }
        next unless node.text.match?(Mentions::PATTERN)

        replacement = Nokogiri::HTML::DocumentFragment.parse('')
        cursor = 0
        node.text.to_enum(:scan, Mentions::PATTERN).each do
          match = Regexp.last_match
          replacement.add_child(Nokogiri::XML::Text.new(node.text[cursor...match.begin(0)], fragment.document))
          href = yield Mentions.normalize(match[1])
          if href
            link = Nokogiri::XML::Node.new('a', fragment.document)
            link['href'] = href
            link['class'] = 'b270-mention'
            link['rel'] = LINK_REL
            link.content = match[0]
            replacement.add_child(link)
          else
            replacement.add_child(Nokogiri::XML::Text.new(match[0], fragment.document))
          end
          cursor = match.end(0)
        end
        replacement.add_child(Nokogiri::XML::Text.new(node.text[cursor..].to_s, fragment.document))
        node.replace(replacement)
      end
    end
    private_class_method :link_mentions
  end
end
