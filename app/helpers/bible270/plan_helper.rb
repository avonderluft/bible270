# frozen_string_literal: true

module Bible270
  module PlanHelper
    def b270_track(track)
      Plan::TRACKS.fetch(track.to_s)
    end

    # Path that begins the OmniAuth request phase. Must be POSTed to: OmniAuth
    # 2.0+ refuses GET on its own routes (CVE-2015-9284), so every sign-in
    # control in these views is a button_to, not a link_to.
    def b270_omniauth_path(provider)
      prefix = Bible270.config.omniauth_path_prefix || "#{request.script_name}/auth"
      "#{prefix}/#{provider}"
    end

    def b270_provider_label(provider)
      Bible270.config.label_for_provider(provider)
    end

    # The signed-in reader's translation, falling back to the site default for
    # visitors who aren't signed in.
    # Applies to every page the engine's layout renders, i.e. everything under
    # the mount point. Pages rendered inside a host layout need this in that
    # layout's <head> instead.
    # The footer, from whichever source the host configured. A partial is looked
    # up in the host's view paths as well as the engine's, so 'shared/footer'
    # finds app/views/shared/_footer.html.erb.
    # The footer, from whichever source the host configured. A partial is looked
    # up in the host's view paths as well as the engine's, so 'shared/footer'
    # finds app/views/shared/_footer.html.erb. config.footer_placement decides
    # whether a custom footer replaces the engine's or sits alongside it.
    def b270_footer
      config = Bible270.config
      return if config.footer_style == :none
      return render('bible270/shared/footer') if config.footer_style == :default

      parts = [b270_custom_footer]
      if config.keep_default_footer?
        default = render('bible270/shared/footer')
        config.resolved_footer_placement == :after ? parts.unshift(default) : parts.push(default)
      end

      safe_join(parts)
    end

    def b270_custom_footer
      case Bible270.config.footer_style
      when :partial then render(Bible270.config.footer_partial)
      when :html then content_tag(:footer, Bible270.config.footer_html.html_safe, class: 'b270-footer')
      end
    end

    # The mark beside the title in the header. Larger than the favicon and inlined
    # as SVG, so it stays crisp at any size and needs no asset pipeline.
    def b270_mark(size: 38)
      configured = Bible270.config.header_mark
      return nil if configured == false

      if configured.is_a?(String) && configured.present?
        return image_tag(configured, width: size, height: size, alt: '', class: 'b270-mark')
      end

      content_tag :span, Favicon.inline_svg(size: size).html_safe, class: 'b270-mark'
    end

    def b270_favicon_tag
      favicon = Bible270.config.favicon
      return if favicon == false

      href = favicon.presence || Favicon.data_uri
      type = href.start_with?('data:image/svg+xml', 'http') || href.end_with?('.svg') ? 'image/svg+xml' : nil
      tag.link(rel: 'icon', type: type, href: href)
    end

    def b270_bible_version
      current_reader&.effective_bible_version || Translations.resolve(nil)
    end

    def b270_passage_url(reference, version = nil)
      return '#' if reference.blank?

      Bible270.config.passage_url_builder.call(reference, version || b270_bible_version)
    end

    # Small grey "(NKJV)" after a reading, so it's clear which translation the
    # link opens in.
    def b270_version_tag(version = nil)
      content_tag :span, "(#{version || b270_bible_version})", class: 'b270-version'
    end

    def b270_avatar_src(reader)
      return main_app.rails_blob_path(reader.avatar, only_path: true) if reader.avatar_uploaded?

      reader.avatar_url.presence
    end

    def b270_avatar(reader, size: 34)
      src = b270_avatar_src(reader)
      if src
        image_tag src, class: 'b270-avatar', width: size, height: size, alt: reader.display_name
      else
        content_tag :span, reader.initials, class: 'b270-avatar b270-avatar-fallback',
                                            style: "width:#{size}px;height:#{size}px;line-height:#{size}px"
      end
    end

    def b270_day_status_class(reader, day)
      return '' unless reader

      case reader.day_status(day)
      when :complete then 'complete'
      when :partial  then 'partial'
      else ''
      end
    end
  end
end
