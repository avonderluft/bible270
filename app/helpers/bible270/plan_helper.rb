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
      return "#" if reference.blank?
      Bible270.config.passage_url_builder.call(reference, Bible270.config.bible_version)
    end

    def b270_avatar(reader, size: 34)
      if reader.avatar_url.present?
        image_tag reader.avatar_url, class: "b270-avatar", width: size, height: size, alt: reader.display_name
      else
        content_tag :span, reader.initials, class: "b270-avatar b270-avatar-fallback",
                    style: "width:#{size}px;height:#{size}px;line-height:#{size}px"
      end
    end

    def b270_day_status_class(reader, day)
      return "" unless reader
      if reader.day_complete?(day)
        "complete"
      elsif reader.read_tracks_for(day).any?
        "partial"
      else
        ""
      end
    end
  end
end
