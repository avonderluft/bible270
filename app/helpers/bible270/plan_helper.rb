# frozen_string_literal: true

module Bible270
  module PlanHelper
    PASSAGE_LINK_TARGET = 'bible270_scripture'

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
    # Renders "@handle" as a link to that reader. An unresolved or ambiguous handle
    # is left as plain text, which is how a writer discovers it found nobody.
    #
    # Built by walking the matches and escaping everything between them, rather
    # than escaping afterwards: the body is reader-supplied, so the only safe
    # construction is one where every non-link fragment is escaped by hand.
    def b270_with_mentions(body)
      text = body.to_s
      readers = Bible270::Reader.mentioned_in(text)

      pieces = []
      cursor = 0

      text.to_enum(:scan, Bible270::Mentions::PATTERN).each do
        match = Regexp.last_match
        pieces << ERB::Util.html_escape(text[cursor...match.begin(0)])

        handle = Bible270::Mentions.normalize(match[1])
        reader = readers.find { |candidate| candidate.answers_to?(handle) }
        pieces << if reader
                    link_to(match[0], reader_path(reader), class: 'b270-mention')
                  else
                    ERB::Util.html_escape(match[0])
                  end

        cursor = match.end(0)
      end

      pieces << ERB::Util.html_escape(text[cursor..].to_s)
      safe_join(pieces)
    end

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

      selected_version = version || b270_bible_version
      if selected_version != Translations::ORIGINAL_LANGUAGES && current_reader&.blue_letter_bible?
        return Translations.passage_url(reference, selected_version, blue_letter: true)
      end

      Translations.passage_url(reference, selected_version)
    end

    # The named target is the no-JavaScript fallback. Interaction UI retains one
    # tab handle for iOS Safari, nulls its opener before external navigation, and
    # reuses it; noopener keeps the ordinary fallback secure.
    def b270_passage_link(reference, **options)
      data = options.fetch(:data, {}).merge(b270_passage_link: true)
      options.merge!(data: data, target: PASSAGE_LINK_TARGET, rel: 'noopener')
      link_to reference, b270_passage_url(reference), options
    end

    # Small grey "(NKJV)" after a reading, so it's clear which translation the
    # link opens in. The original-language preference names the actual language
    # used for each track rather than repeating the combined preference code.
    def b270_version_tag(version = nil, track: nil)
      label = version || b270_bible_version
      if label == Translations::ORIGINAL_LANGUAGES && track
        label = track.to_s == 'nt' ? 'Greek' : 'Hebrew'
      end

      content_tag :span, "(#{label})", class: 'b270-version'
    end

    def b270_avatar_src(reader)
      return main_app.rails_blob_path(reader.avatar, only_path: true) if reader.avatar_uploaded?

      reader.avatar_url.presence
    end

    def b270_avatar(reader, size: 72)
      src = b270_avatar_src(reader)
      if src
        image_tag src, class: 'b270-avatar', width: size, height: size, alt: reader.display_name
      else
        content_tag :span, reader.initials, class: 'b270-avatar b270-avatar-fallback',
                                            style: "width:#{size}px;height:#{size}px;line-height:#{size}px"
      end
    end

    # Timestamps in the plan's zone rather than UTC. Dates — started_on and the
    # like — need no conversion and are formatted inline.
    def b270_date(time)
      local = Bible270.local_time(time)
      local&.strftime('%b %-d, %Y')
    end

    def b270_datetime(time)
      local = Bible270.local_time(time)
      local&.strftime('%b %-d, %Y at %-I:%M %p')
    end

    # Only the writer may change their own words. An admin can remove a reflection
    # but not rewrite it: putting words in someone's mouth is worse than taking
    # them away, and taking them away is already the moderator's job.
    def b270_can_edit?(comment)
      signed_in? && comment.reader_id == current_reader.id
    end

    def b270_can_delete?(comment)
      return false unless signed_in?

      comment.reader_id == current_reader.id || Bible270.config.admin?(current_reader)
    end

    # One cell of the 270-day grid. Four views drew this by hand in four slightly
    # different ways; now they all call this.
    #
    # The title attribute carries the readings for pointer users; aria-label also
    # includes date, progress, today, and reflection state for assistive technology.
    def b270_day_cell(day, reader: nil, today: nil)
      link_to day, day_path(day),
              class: b270_day_cell_classes(day, reader: reader, today: today),
              title: b270_day_readings(day),
              aria: { label: b270_day_cell_label(day, reader: reader, today: today) }
    end

    def b270_day_cell_label(day, reader: nil, today: nil)
      parts = ["Day #{day}"]
      parts << reader.date_for_day(day).strftime('%A, %B %-d, %Y') if reader&.dated?
      if reader
        status = { complete: 'complete', partial: 'partially read', none: 'not read' }.fetch(reader.day_status(day))
        parts << status
      end
      parts << 'today' if today == day
      parts << 'has reflections' if b270_days_with_reflections.include?(day)
      parts << b270_day_readings(day)
      parts.join('. ')
    end

    # Shared with the admin grid, which is a button_to rather than a link because
    # it toggles the day rather than navigating to it.
    def b270_day_cell_classes(day, reader: nil, today: nil)
      classes = ['b270-cell', b270_day_status_class(reader, day)]
      classes << 'talk' if b270_days_with_reflections.include?(day)
      classes << 'now' if today && day == today

      classes.reject(&:blank?).join(' ')
    end

    # "Genesis 1-3 · Matthew 1 · Psalm 1" as plain text, for a title attribute.
    def b270_day_readings(day)
      readings = Bible270::Plan.readings_for(day)
      Bible270::Plan::TRACKS.keys.filter_map { |track| readings[track] }.join(' · ')
    end

    # The same references as links to the passage, in the reader's own translation
    # when they have chosen one — b270_passage_url falls back to the site default
    # for a visitor.
    def b270_day_reading_links(day)
      readings = Bible270::Plan.readings_for(day)

      links = Bible270::Plan::TRACKS.keys.filter_map do |track|
        reference = readings[track]
        next if reference.blank?

        b270_passage_link reference, class: 'b270-reflink'
      end

      safe_join(links, ' · ')
    end

    # The days that have at least one visible reflection, fetched once per request.
    # Called from the layout's grid, which no controller sets up, so it cannot be an
    # instance variable assigned in an action.
    def b270_days_with_reflections
      @b270_days_with_reflections ||=
        if defined?(Bible270::Comment)
          Bible270::Comment.approved.distinct.pluck(:day).to_set
        else
          Set.new
        end
    rescue StandardError
      Set.new
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
