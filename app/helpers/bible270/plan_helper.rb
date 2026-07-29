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

    def b270_passage_url(reference)
      return '#' if reference.blank?

      Bible270.config.passage_url_builder.call(reference, Bible270.config.bible_version)
    end

    # An uploaded avatar wins over whatever the sign-in provider gave us.
    # Active Storage routes live in the host app, hence main_app.
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
