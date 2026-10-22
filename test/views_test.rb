# frozen_string_literal: true

require 'test_helper'
require 'erb'

# Rails compiles a template into a method on an anonymous ActionView subclass.
# Its lexical scope is Object, *not* Bible270 — including PlanHelper doesn't
# help, because constant lookup doesn't walk into a module's namespace. So a
# bare `Plan::DAYS` in a template raises
#
#   uninitialized constant #<Class:0x...>::Plan
#
# at render time, even though the identical code is fine in a controller or
# helper (both of which sit lexically inside `module Bible270`).
#
# These checks are static, so they catch it without booting Rails.
class ViewsTest < Minitest::Test
  ENGINE_CONSTANTS = %w[
    Plan Versification Reader Checkoff Comment SignInToken EmailSignIn Configuration Engine
  ].freeze

  VIEW_ROOT = File.expand_path('../app/views', __dir__)

  def templates
    @templates ||= Dir.glob(File.join(VIEW_ROOT, '**', '*.erb'))
  end

  def test_there_are_templates_to_check
    refute_empty templates, 'expected to find ERB templates to scan'
  end

  def test_engine_constants_are_namespaced_in_templates
    pattern = %r{(?<![:A-Za-z_])(#{ENGINE_CONSTANTS.join('|')})(?=[.:])}

    offenders = templates.flat_map do |path|
      File.readlines(path, chomp: true).each_with_index.filter_map do |line, i|
        next unless line.match?(pattern)
        # Bible270::Plan is fine; a bare Plan is not.
        next if line.scan(pattern).all? { |(const)| line.include?("Bible270::#{const}") }

        "#{path.sub("#{VIEW_ROOT}/", '')}:#{i + 1}  #{line.strip}"
      end
    end

    assert_empty offenders, <<~MSG
      Engine constants must be fully qualified in templates (Bible270::Plan, not Plan).
      A template's lexical scope is Object, so a bare reference raises
      "uninitialized constant" at render time:

      #{offenders.join("\n      ")}
    MSG
  end

  def test_helpers_used_in_templates_are_defined
    helper_source = File.read(File.expand_path('../app/helpers/bible270/plan_helper.rb', __dir__))
    defined_helpers = helper_source.scan(%r{def (b270_\w+)}).flatten.sort

    used = templates.flat_map { |p| File.read(p).scan(%r{(?<![:\w])(b270_\w+)\s*\(}) }.flatten.uniq.sort
    missing = used - defined_helpers

    assert_empty missing, "templates call helpers that don't exist: #{missing.inspect}"
  end

  # The engine's helpers are only auto-included when the controller's superclass
  # is exactly ActionController::Base, which is not the case once
  # config.parent_controller points at the host app. If this include is ever
  # dropped, every b270_* call in a view raises NoMethodError at render time.
  def test_application_controller_includes_the_engine_helpers
    source = File.read(File.expand_path('../app/controllers/bible270/application_controller.rb', __dir__))

    assert_match(%r{^\s*helper\s+(:all|Bible270::PlanHelper)}, source,
                 'Bible270::ApplicationController must include the engine helpers explicitly')
  end

  # `.b270 a{color:inherit}` has specificity (0,1,1). A bare `.b270-btn{color:…}`
  # is (0,1,0), so on an <a class="b270-btn"> the blanket rule wins and the label
  # inherits the body colour — dark text on a dark button. Any class that colours
  # an anchor therefore has to outrank it.
  STYLES = File.expand_path('../app/views/bible270/shared/_styles.html.erb', __dir__)

  def specificity(selector)
    sel = selector.strip
    [sel.scan(%r{#[\w-]+}).size,
     sel.scan(%r{\.[\w-]+|\[[^\]]+\]|:(?!:)[\w-]+}).size,
     sel.scan(%r{(?:\A|[\s>+~])([a-z]+[\w-]*)}).size]
  end

  # Classes the templates actually put on an <a>.
  def anchor_classes
    templates.flat_map { |p| File.read(p).scan(%r{link_to[^\n]*?class:\s*"([^"]*)"}) }
      .flatten
      .flat_map(&:split)
      .grep(%r{\Ab270-[\w-]+\z})
      .uniq
  end

  def colour_rules
    File.read(STYLES).scan(%r{^\s*([^\n{@]+)\{([^}]*)\}}m)
      .select { |_, body| body.match?(%r{(?<![\w-])color\s*:}) }
  end

  def test_theme_script_is_loaded_globally_and_header_control_is_compact_and_accessible
    layout = File.read(File.join(VIEW_ROOT, 'layouts/bible270/application.html.erb'))
    header = File.read(File.join(VIEW_ROOT, 'bible270/shared/_header.html.erb'))
    styles = File.read(STYLES)

    assert_includes layout, 'render "bible270/shared/theme_ui"'
    %w[bible270/profiles/edit.html.erb bible270/admin/show.html.erb].each do |path|
      refute_includes File.read(File.join(VIEW_ROOT, path)), 'render "bible270/shared/theme_ui"'
    end
    assert_includes header, 'current_reader && Bible270::Reader.display_mode_column?'
    assert_includes header, 'aria: { label: "Theme", describedby: "b270-header-theme-status" }'
    assert_includes styles, '.b270-header-theme-select{font:inherit;'
    assert_includes styles, '.b270-header-theme-select{font:inherit;font-size:12px;width:6.5em;height:28px;padding:2px;margin:0;'
    assert_includes styles, '.b270-header-theme-select{field-sizing:content;width:auto}'
    assert_equal 1, styles.scan(%r{\.b270-header-theme-select\{[^\}]*font-size:}).size
    assert_includes styles, '.b270-brand{display:flex;align-items:baseline;gap:14px;'
    assert_includes styles, '.b270-header-theme{position:relative;display:flex;align-items:baseline;'
    assert_includes styles, '.b270-brandlink{display:flex;align-items:baseline;'
    assert_match(%r{\.b270-topbar\{[^\}]*flex-wrap:nowrap}, styles)
    assert_match(%r{@media \(max-width:820px\)\{.*?\.b270-desktopnav\{display:none\}.*?\.b270-navmenu\{display:block\}}m, styles)
    assert_includes styles, '.b270-header-theme-status[data-error="true"]'
  end

  def test_header_brand_uses_the_same_small_size_and_spacing_at_every_breakpoint
    styles = File.read(STYLES)

    assert_includes styles, '.b270-brandlink{display:flex;align-items:baseline;gap:6px;'
    assert_includes styles, '.b270-mark svg,.b270-mark img,.b270-brandlink > img.b270-mark{display:block;width:28px;height:28px;border-radius:8px}'
    assert_match(%r{\.b270-title\{[^\}]*font-size:18px;}, styles)
    assert_equal 1, styles.scan(%r{\.b270-title\{}).size
    assert_equal 1, styles.scan(%r{\.b270-brandlink\{}).size
  end

  def test_admin_progress_link_is_quiet_until_hover_or_focus
    styles = File.read(STYLES)

    assert_match(%r{\.b270-li \.b270-admin-progress\{text-decoration:none\}}, styles)
    assert_match(%r{\.b270-admin-progress:hover.*\.b270-admin-progress:focus-visible\{color:var\(--gold\)\}},
                 styles)
  end

  def test_anchor_colour_rules_outrank_the_blanket_anchor_rule
    refute_empty anchor_classes, 'expected to find engine classes used on links'
    blanket = specificity('.b270 a')

    offenders = anchor_classes.filter_map do |klass|
      rules = colour_rules.select { |sel, _| sel.include?(".#{klass}") }
      next if rules.empty? # no colour set: inherit is fine
      next if rules.any? { |_, body| body.include?('!important') }
      next if rules.any? { |sel, _| (specificity(sel) <=> blanket) == 1 }

      "#{klass}: #{rules.map(&:first).map(&:strip).inspect} all lose to '.b270 a' #{blanket.inspect}"
    end

    assert_empty offenders, <<~MSG
      These classes colour an <a> but lose to `.b270 a{color:inherit}`, so the link
      will inherit the body colour instead (e.g. dark-on-dark buttons). Qualify the
      rule with `.b270 ` to raise its specificity:

      #{offenders.join("\n      ")}
    MSG
  end

  # An Old Testament reading is several rows now, so a "who finished this day"
  # query that counts against required_track_count credits someone who has read
  # only the Old Testament.
  def test_the_completers_query_counts_boxes_not_tracks
    offenders = Dir.glob(File.expand_path('../app/controllers/**/*.rb', __dir__)).select do |path|
      File.readlines(path)
        .reject { |line| line.strip.start_with?('#') }
        .any? { |line| line.include?('required_track_count') }
    end

    assert_empty offenders.map { |path| File.basename(path) },
                 'counting tracks calls a partly-read day finished; count total_parts'
  end

  # An ERB comment ends at the first %>, so an example containing <%= ... %>
  # closes it early and the remainder becomes live template code. A doc comment in
  # _progress.html.erb once made the partial render itself.
  def test_no_erb_tags_inside_erb_comments
    offenders = templates.flat_map do |path|
      body = File.read(path)
      # Each <%# ... %> block: flag one whose body contains an opening ERB tag.
      body.scan(%r{<%#(.*?)%>}m).flatten.filter_map do |comment|
        "#{path.sub("#{VIEW_ROOT}/", '')}: #{comment.strip[0, 60]}" if comment.include?('<%')
      end
    end

    assert_empty offenders, <<~MSG
      An ERB comment ends at the first %>, so these leak code into the template:

      #{offenders.join("\n      ")}
    MSG
  end

  # The engine inlines its stylesheet, so every class name it defines appears in
  # every response body. A test asserting on a bare /b270-something/ is really
  # asserting that the stylesheet exists — it passes whether or not the markup is
  # there. Assertions must match the class attribute instead.
  def test_no_test_asserts_on_a_bare_engine_class_name
    styles = File.read(File.expand_path('../app/views/bible270/shared/_styles.html.erb', __dir__))
    defined_classes = styles.scan(%r{\.(b270-[a-z-]+)}).flatten.uniq

    offenders = Dir.glob(File.expand_path('*_test.rb', __dir__)).flat_map do |path|
      File.readlines(path, chomp: true).each_with_index.filter_map do |line, i|
        next unless line.match?(%r{(?:assert|refute)_match})

        bare = line.scan(%r{(?:/|%r\{)(b270-[a-z-]+)(?:/|\})}).flatten
        hit = bare.find { |name| defined_classes.include?(name) }
        "#{File.basename(path)}:#{i + 1}  #{hit}" if hit
      end
    end

    assert_empty offenders, <<~MSG
      These assert on a class name the stylesheet defines, so they match the
      inlined CSS rather than the markup:

      #{offenders.join("\n      ")}
    MSG
  end

  # A view reading an instance variable its controller never assigns renders nil,
  # and the failure arrives as whatever nil cannot do — "undefined method 'any?'
  # for nil" from somewhere in the middle of a template.
  #
  # The lookbehind keeps email placeholders like "you@example.com" out of it.
  def test_views_only_read_instance_variables_their_controller_assigns
    root = File.expand_path('..', __dir__)
    offenders = []

    Dir.glob(File.join(root, 'app/views/bible270/*/*.erb')).each do |view|
      next if File.basename(view).start_with?('_')

      controller = File.join(root, "app/controllers/bible270/#{File.basename(File.dirname(view))}_controller.rb")
      next unless File.exist?(controller)

      used = File.read(view).scan(%r{(?<![\w.])@([a-z_][a-z0-9_]*)}).flatten.uniq
      assigned = File.read(controller).scan(%r{@([a-z_][a-z0-9_]*)\s*(?:\|\|)?=}).flatten.uniq

      (used - assigned).each do |name|
        offenders << "#{view.sub("#{root}/app/views/bible270/", '')}: @#{name}"
      end
    end

    assert_empty offenders, <<~MSG
      These views read instance variables their controller does not assign:

      #{offenders.join("\n      ")}
    MSG
  end

  # A timestamp formatted straight from the record renders in Rails' Time.zone,
  # which is UTC unless the host app sets one — so a reflection written at 5pm in
  # Los Angeles showed as the next day. Bible270.local_time is the same rule
  # Bible270.today follows. Dates (started_on and the like) carry no zone and are
  # formatted inline.
  def test_timestamps_are_rendered_in_the_plans_zone
    root = File.expand_path('..', __dir__)
    offenders = Dir.glob(File.join(root, 'app/**/*.erb')).flat_map do |path|
      File.readlines(path, chomp: true).each_with_index.filter_map do |line, i|
        next unless line.match?(%r{(?:created_at|updated_at|closed_at)\.strftime})

        "#{path.sub("#{root}/app/views/bible270/", '')}:#{i + 1}"
      end
    end

    assert_empty offenders, <<~MSG
      These format a timestamp without converting it first — use b270_date,
      b270_datetime, or Bible270.local_time:

      #{offenders.join("\n      ")}
    MSG
  end

  def test_templates_do_not_call_removed_plan_methods
    removed = %w[
      nt_groups nt_days_per_pass nt_second_pass_start_day
      pp_base_portions pp_cycle_length format_pp pp_segment_length
    ]
    offenders = templates.flat_map do |path|
      File.readlines(path, chomp: true).each_with_index.filter_map do |line, i|
        hit = removed.find { |m| line.match?(%r{\.#{m}\b}) }
        "#{path.sub("#{VIEW_ROOT}/", '')}:#{i + 1}  calls removed #{hit}" if hit
      end
    end

    assert_empty offenders, offenders.join("\n")
  end

  def test_accessibility_styles_cover_focus_touch_mobile_and_reduced_motion
    styles = File.read(STYLES)

    assert_match(%r{:where\(a,button,input,select,textarea,summary\):focus-visible}, styles)
    assert_match(%r{\.b270-likes:active \.b270-liketooltip}, styles)
    assert_match(%r{\.b270-form \.row\{align-items:stretch;flex-direction:column\}}, styles)
    assert_match(%r{@media \(prefers-reduced-motion:reduce\)}, styles)
  end

  def test_mobile_menu_icon_uses_theme_text_colour_instead_of_background_bars
    styles = File.read(STYLES)

    assert_includes styles, '.b270-menuicon{display:block;flex:none;color:var(--ink)}'
    assert_includes styles, '.b270-navtoggle[aria-expanded="true"] .b270-menuicon{color:var(--gold)}'
    refute_includes styles, '.b270-menuicon span'
  end

  def test_readable_palette_colours_meet_aa_contrast
    styles = File.read(STYLES)
    selectors = ['.b270'] + %w[sage mist dark dark_green dark_blue system].map { |mode| ".b270[data-display-mode=\"#{mode}\"]" }
    selectors.each do |selector|
      palette = styles.match(%r{#{Regexp.escape(selector)}\{([^\}]+)})[1]
      colours = palette.scan(%r{--([a-z-]+):#([0-9a-f]{3,6})}).to_h.transform_values do |hex|
        hex.length == 3 ? hex.chars.map { |char| char * 2 }.join : hex
      end

      %w[ink muted faint gold teal oxblood].product(%w[paper card control]).each do |foreground, background|
        assert_operator contrast_ratio(colours.fetch(foreground), colours.fetch(background)), :>=, 4.5,
                        "#{selector}: --#{foreground} must meet AA contrast against --#{background}"
      end
      %w[gold-lite teal-fill oxblood-fill gold-fill].each do |background|
        assert_operator contrast_ratio(colours.fetch('on-accent'), colours.fetch(background)), :>=, 4.5,
                        "#{selector}: badge and checkmark text must contrast with --#{background}"
      end
      %w[button-surface button-hover].each do |background|
        assert_operator contrast_ratio(colours.fetch('button-ink'), colours.fetch(background)), :>=, 4.5,
                        "#{selector}: button text must contrast with --#{background}"
      end
    end
  end

  def test_dark_theme_uses_dark_fills_and_separate_readable_text_colours
    styles = File.read(STYLES)

    assert_includes styles, '--paper:#39311f; --card:#322714; --ink:#ccc9bd'
    assert_includes styles, '--control:#181b1b'
    assert_includes styles, '--button-surface:#201c12; --button-ink:#ded8c5'
    assert_includes styles, 'background:var(--button-surface);color:var(--button-ink)'
    %w[teal oxblood gold].each do |accent|
      assert_includes styles, "background:var(--#{accent}-fill);border-color:var(--#{accent}-mark)"
    end
  end

  def test_forest_and_midnight_themes_define_complete_distinct_dark_palettes
    styles = File.read(STYLES)
    brown = styles.match(%r{\.b270\[data-display-mode="dark"\]\{([^\}]+)})[1]
    variables = brown.scan(%r{(--[a-z-]+):}).flatten.sort
    palettes = %w[dark_green dark_blue].map do |mode|
      palette = styles.match(%r{\.b270\[data-display-mode="#{mode}"\]\{([^\}]+)})[1]
      assert_includes palette, 'color-scheme:dark'
      assert_includes palette, 'background-image:none'
      assert_equal variables, palette.scan(%r{(--[a-z-]+):}).flatten.sort
      colours = palette.scan(%r{--([a-z-]+):#([0-9a-f]{6})}).to_h
      %w[paper card control].each do |surface|
        assert_operator contrast_ratio(colours.fetch('control-line'), colours.fetch(surface)), :>=, 3
      end
      colours.fetch('paper')
    end
    assert_equal %w[1c3027 182537], palettes
  end

  def test_sage_and_mist_themes_define_complete_distinct_light_palettes
    styles = File.read(STYLES)
    defaults = styles.match(%r{\.b270-reader-theme,\s*\.b270\{([^\}]+)})[1]
    variables = defaults.scan(%r{(--[a-z-]+):}).flatten.sort
    palettes = %w[sage mist].map do |mode|
      palette = styles.match(%r{\.b270\[data-display-mode="#{mode}"\]\{([^\}]+)})[1]
      assert_includes palette, 'color-scheme:only light'
      assert_includes palette, 'background-image:none'
      assert_equal variables, palette.scan(%r{(--[a-z-]+):}).flatten.sort
      colours = palette.scan(%r{--([a-z-]+):#([0-9a-f]{6})}).to_h
      %w[paper card control].each do |surface|
        assert_operator contrast_ratio(colours.fetch('control-line'), colours.fetch(surface)), :>=, 3
      end
      %w[alert notice].each do |type|
        assert_operator contrast_ratio(colours.fetch("#{type}-ink"), colours.fetch("#{type}-surface")), :>=, 4.5
      end
      colours.fetch('paper')
    end
    assert_equal %w[e1e8df e2e7ed], palettes
  end

  def test_explicit_light_palettes_force_light_on_the_page_root_but_not_system_or_defaults
    styles = File.read(STYLES)
    defaults = styles.match(%r{\.b270-reader-theme,\s*\.b270\{([^\}]+)})[1]
    assert_includes defaults, 'color-scheme:light;'
    refute_includes defaults, 'color-scheme:only light'

    root = styles.match(%r{(:root\[data-b270-display-mode="light"\][^{}]+)\{([^{}]+)\}})
    refute_nil root
    assert_equal %w[light sage mist].map { |mode| ":root[data-b270-display-mode=\"#{mode}\"]" }, root[1].split(',').map(&:strip)
    assert_equal 'color-scheme:only light', root[2]
    refute_includes styles, ':root:has('
    assert_includes styles, ':root[data-b270-display-mode="system"]{color-scheme:light dark}'
    %w[light sage mist].each do |mode|
      assert_match(%r{\.b270-reader-theme\[data-display-mode="#{mode}"\],\s*\.b270\[data-display-mode="#{mode}"\]\{\s*color-scheme:only light[;\}]}, styles)
    end
    scenery_css_rules(styles).each do |selector, declarations|
      next unless selector.include?('[data-display-mode="system"]')

      refute_includes declarations, 'color-scheme:only light'
    end
  end

  def test_light_theme_surfaces_match_papyrus_brightness
    styles = File.read(STYLES)
    defaults = styles.match(%r{\.b270-reader-theme,\s*\.b270\{([^\}]+)})[1]
    papyrus = defaults.scan(%r{--([a-z-]+):#([0-9a-f]{6})}).to_h

    %w[sage mist].each do |mode|
      palette = styles.match(%r{\.b270\[data-display-mode="#{mode}"\]\{([^\}]+)})[1]
      colours = palette.scan(%r{--([a-z-]+):#([0-9a-f]{6})}).to_h
      %w[paper card].each do |surface|
        assert_in_delta relative_luminance(papyrus.fetch(surface)), relative_luminance(colours.fetch(surface)), 0.01,
                        "#{mode}: --#{surface} should have similar brightness to Papyrus"
      end
    end
  end

  def test_admin_reader_rows_share_all_palettes_without_inheriting_body_layout
    styles = File.read(STYLES)
    defaults = styles.match(%r{\.b270-reader-theme,\s*\.b270\{([^\}]+)})[1]
    assert_includes defaults, '--paper:#ece6da'
    assert_includes defaults, 'color-scheme:light'
    refute_includes defaults, 'margin:'
    refute_includes defaults, 'font-family:'
    %w[light sage mist dark dark_green dark_blue system].each do |mode|
      assert_match(%r{\.b270-reader-theme\[data-display-mode="#{mode}"\],\s*\.b270\[data-display-mode="#{mode}"\]\{}, styles)
    end
    assert_includes styles, '.b270-li.b270-reader-theme{background:var(--card);color:var(--ink)}'
  end

  def test_theme_scenery_is_decorative_and_scoped_to_its_own_page_theme
    styles = File.read(STYLES)
    scenery = File.read(File.join(VIEW_ROOT, 'bible270/shared/_theme_scenery.html.erb'))
    layout = File.read(File.join(VIEW_ROOT, 'layouts/bible270/application.html.erb'))
    illustrations = scenery.scan(%r{<svg[^>]*data-scenery="([^"]+)"[^>]*>(.*?)</svg>}m).to_h

    assert_includes layout, 'render "bible270/shared/theme_scenery"'
    assert_equal %w[mist_sky mist ocean_gulls sage_sky sage light dark dark_green dark_blue hebrew_water scripture], illustrations.keys
    assert_equal 11, scenery.scan('aria-hidden="true" focusable="false"').size
    assert_includes illustrations.fetch('mist'), 'id="b270-ocean-beach"'
    assert_includes illustrations.fetch('sage'), 'fill="url(#b270-meadow-rays)"'
    assert_includes illustrations.fetch('sage'), '<circle cx="1560"'
    assert_match(%r{data-scenery="sage"[^>]*preserveAspectRatio="xMaxYMax slice"}, scenery)
    refute_match(%r{<(?:image|script|animate)\b}, scenery)
    ids = scenery.scan(%r{\bid="([^"]+)"}).flatten
    assert_equal ids.uniq, ids
    assert_match(%r{\.b270-theme-scenery\{display:none;[^\}]*position:fixed;[^\}]*z-index:-1;pointer-events:none}, styles)
    assert_includes styles, '.b270{isolation:isolate}'
    assert_includes styles, '.b270 > .b270-theme-scripture{display:block;color:var(--gold)}'
    %w[mist sage light dark dark_green dark_blue].each do |mode|
      assert_includes styles, ".b270[data-display-mode=\"#{mode}\"] > .b270-theme-scenery[data-scenery=\"#{mode}\"]"
    end
    assert_match(%r{@media print\{\s*\.b270\[data-display-mode\] > \.b270-theme-scenery\[data-scenery\]\{display:none\}}, styles)
    refute_includes styles, '.b270-reader-theme > .b270-theme-scenery'
  end

  def test_phone_scenery_reduces_height_and_hides_scripture_without_changing_desktop_defaults
    styles = File.read(STYLES)
    phone = phone_scenery_styles(styles)
    rules = scenery_css_rules(phone).to_h
    desktop = styles.sub(phone, '')

    assert_equal '--b270-scene-height:clamp(180px,30vh,260px)', rules.fetch('.b270-theme-scenery')
    assert_equal 'display:none', rules.fetch('.b270[data-display-mode] > .b270-theme-scripture')
    assert_equal 'display:none', rules.fetch('.b270[data-display-mode] > .b270-theme-scenery[data-scenery="hebrew_water"]')
    assert_match(%r{\.b270-theme-scenery\{display:none;--b270-scene-height:clamp\(280px,52vh,560px\);[^\}]*height:var\(--b270-scene-height\)}, desktop)
    assert_includes desktop, '.b270 > .b270-theme-scripture{display:block;color:var(--gold)}'
    assert_includes desktop, '.b270-theme-scripture{height:clamp(380px,76vh,820px)}'
    assert_includes scenery_css_rules(desktop), ['.b270[data-display-mode="dark_blue"] > .b270-theme-scenery[data-scenery="hebrew_water"]', 'display:block']
    refute_includes desktop, '#b270-lake-reflection'
    refute_match(%r{\.b270-theme-scripture[^{}]*\{[^\}]*display:none}, desktop)
    refute_match(%r{\[data-scenery="hebrew_water"\][^{}]*\{[^\}]*display:none}, desktop)

    outside_rules = scenery_css_rules(desktop)
    scenery_css_rules(phone).each do |rule|
      refute_includes outside_rules, rule, "phone simplification must not escape max-width:600px: #{rule.first}"
    end
  end

  def test_phone_artwork_simplifications_cover_all_six_themes_and_target_existing_layers
    styles = File.read(STYLES)
    rules = scenery_css_rules(phone_scenery_styles(styles)).to_h
    artwork = Nokogiri::HTML.fragment(File.read(File.join(VIEW_ROOT, 'bible270/shared/_theme_scenery.html.erb')))
    accents = {
      '.b270-papyrus-grid' => 'opacity:.2',
      '.b270-papyrus-edges' => 'opacity:.55',
      '.b270-theme-scenery[data-scenery="sage_sky"]' => 'opacity:.3',
      '#b270-meadow-clouds' => 'opacity:.5',
      '#b270-meadow-grass-near' => 'opacity:.15',
      '.b270-theme-scenery[data-scenery="sage"] [fill="url(#b270-meadow-rays)"]' => 'opacity:.25',
      '.b270-theme-scenery[data-scenery="mist_sky"]' => 'opacity:.2',
      '.b270-theme-scenery[data-scenery="mist"]' => 'opacity:.45',
      '.b270-theme-scenery[data-scenery="dark"]' => 'height:clamp(240px,42vh,380px);opacity:.45'
    }
    hidden_details = [
      '#b270-meadow-clouds path:nth-child(even)',
      '#b270-meadow-grass-distant',
      '#b270-meadow-grass-near path:not(:nth-child(3n + 1))',
      '#b270-ocean-clouds', '#b270-ocean-distant-waves', '#b270-ocean-glints', '#b270-ocean-sand-detail',
      '#b270-ocean-surf path:not(:first-child)',
      '#b270-cedar-fine-grain path:not(:first-child)', '#b270-cedar-knots path:nth-child(n + 4)',
      '#b270-spruce-distant path:nth-of-type(even)', '#b270-spruce-near path:nth-of-type(even)',
      '#b270-spruce-distant path:nth-of-type(n + 22)', '#b270-spruce-near path:nth-of-type(n + 22)',
      '#b270-lake-reflection'
    ]
    accents.merge(hidden_details.to_h { |selector| [selector, 'display:none'] }).each do |selector, declarations|
      assert_equal declarations, rules.fetch(selector), selector
      refute_empty artwork.css(selector), "phone selector must match artwork: #{selector}"
    end
  end

  def test_phone_forest_thins_trees_without_fading_the_opaque_near_layer_or_hiding_ground
    rules = scenery_css_rules(phone_scenery_styles(File.read(STYLES)))
    artwork = Nokogiri::HTML.fragment(File.read(File.join(VIEW_ROOT, 'bible270/shared/_theme_scenery.html.erb')))
    near = artwork.at_css('#b270-spruce-near')
    protected_layers = [near, near.at_css('#b270-spruce-near-ground')] + near.ancestors.select(&:element?)

    rules.each do |selector, declarations|
      next unless artwork.css(selector).to_a.intersect?(protected_layers)

      refute_match(%r{(?:opacity|fill-opacity|mask|filter):|display:none}, declarations, selector)
    end
    %w[distant near].each do |depth|
      trees = artwork.css("#b270-spruce-#{depth} path")
      hidden = artwork.css("#b270-spruce-#{depth} path:nth-of-type(even), #b270-spruce-#{depth} path:nth-of-type(n + 22)")
      assert_equal 11, (trees.to_a - hidden.to_a).size
    end
  end

  def test_mobile_moonlight_is_a_clipped_ellipse_hidden_on_desktop_instead_of_reflected_letters
    styles = File.read(STYLES)
    phone = phone_scenery_styles(styles)
    artwork = Nokogiri::HTML.fragment(File.read(File.join(VIEW_ROOT, 'bible270/shared/_theme_scenery.html.erb')))
    lake = artwork.at_css('svg[data-scenery="dark_blue"]')
    glow = lake.at_css('ellipse.b270-mobile-scenery')

    refute_nil glow
    assert_equal 1, artwork.css('.b270-mobile-scenery').size
    assert_equal(%w[1510 332 65 92], %w[cx cy rx ry].map { |attribute| glow[attribute] })
    assert_equal 'url(#b270-moon-mobile-glow)', glow['fill']
    assert_equal 'url(#b270-lake-clip)', glow.parent['clip-path']
    assert_equal(%w[.18 .07 0], lake.css('#b270-moon-mobile-glow stop').map { |stop| stop['stop-opacity'] })
    assert_equal 'url(#b270-greek-reflection)', glow.parent.at_css('#b270-lake-reflection')['mask']
    assert_includes styles.sub(phone, ''), '.b270-mobile-scenery{display:none}'
    assert_equal 'display:block', scenery_css_rules(phone).to_h.fetch('.b270-mobile-scenery')
    assert_equal 'display:none', scenery_css_rules(phone).to_h.fetch('#b270-lake-reflection')
  end

  def test_phone_scenery_preserves_system_switching_and_print_hides_every_layer
    styles = File.read(STYLES)
    phone = phone_scenery_styles(styles)
    system = styles.match(%r{@media \(prefers-color-scheme:dark\)\{\s*\.b270\[data-display-mode="system"\] > \.b270-theme-scenery.*?\n  \}}m)[0]
    print_styles = styles.match(%r{@media print\{[^{}]*\{[^{}]*\}\s*\}})[0]
    print_selector, print_declarations = scenery_css_rules(print_styles).first
    scenery = File.read(File.join(VIEW_ROOT, 'bible270/shared/_theme_scenery.html.erb'))

    refute_includes phone, 'data-display-mode="system"'
    refute_includes phone, 'color-scheme:'
    assert_includes system, '[data-scenery="light"]{display:none}'
    assert_includes system, '[data-scenery="dark"]{display:block}'
    assert_operator styles.index(phone), :>, styles.index(system)
    assert_operator styles.index(print_styles), :>, styles.index(phone)
    assert_equal 'display:none', print_declarations
    %w[light sage mist dark dark_green dark_blue system].each do |mode|
      page = Nokogiri::HTML.fragment("<div class=\"b270\" data-display-mode=\"#{mode}\">#{scenery}</div>")
      assert_equal page.css('svg.b270-theme-scenery').to_a, page.css(print_selector).to_a, mode
      assert_includes page.css(print_selector).to_a, page.at_css('.b270-mobile-scenery').ancestors('svg').first
    end
  end

  def test_ocean_replaces_mountains_with_an_afternoon_sky_sea_and_sandy_shore
    styles = File.read(STYLES)
    scenery = File.read(File.join(VIEW_ROOT, 'bible270/shared/_theme_scenery.html.erb'))
    ocean = scenery.match(%r{<svg[^>]*data-scenery="mist"[^>]*>(.*?)</svg>}m)[1]
    sky = scenery.match(%r{<svg[^>]*data-scenery="mist_sky"[^>]*>(.*?)</svg>}m)[1]

    assert_includes styles, '.b270[data-display-mode="mist"] > .b270-theme-scenery[data-scenery="mist_sky"]'
    assert_includes styles, '.b270-theme-scenery[data-scenery="mist_sky"]{height:100%}'
    assert_includes sky, 'fill="url(#b270-ocean-sky)"'
    assert_includes sky, 'fill="url(#b270-ocean-afternoon-glow)"'
    %w[horizon beach wash surf distant-waves].each do |feature|
      assert_includes ocean, "id=\"b270-ocean-#{feature}\""
    end
    %w[water sand shimmer].each do |material|
      assert_includes ocean, "url(#b270-ocean-#{material})"
    end
    refute_match(%r{b270-mist-(?:distant|middle|near)}, scenery)
    assert_match(%r{data-scenery="mist"[^>]*preserveAspectRatio="xMidYMax slice"}, scenery)
  end

  def test_ocean_has_two_decorative_gulls_anchored_to_the_lower_right_sand
    styles = File.read(STYLES)
    scenery = File.read(File.join(VIEW_ROOT, 'bible270/shared/_theme_scenery.html.erb'))
    gulls = Nokogiri::HTML.fragment(scenery).at_css('svg[data-scenery="ocean_gulls"]')

    assert_equal 'true', gulls['aria-hidden']
    assert_equal 'false', gulls['focusable']
    assert_equal 2, gulls.css('use[href="#b270-ocean-gull"]').size
    assert_equal '.65', gulls.at_css('.b270-ocean-gulls')['opacity']
    assert_includes styles, '.b270[data-display-mode="mist"] > .b270-theme-scenery[data-scenery="ocean_gulls"]'
    assert_includes styles, '.b270-ocean-gulls{transform-box:view-box;transform:translate(calc(100% - 115px),calc(100% - 35px))}'
  end

  def test_meadow_has_a_full_height_blue_sky_wispy_clouds_and_layered_grass
    styles = File.read(STYLES)
    scenery = File.read(File.join(VIEW_ROOT, 'bible270/shared/_theme_scenery.html.erb'))
    sky = scenery.match(%r{<svg[^>]*data-scenery="sage_sky"[^>]*>(.*?)</svg>}m)[1]
    meadow = scenery.match(%r{<svg[^>]*data-scenery="sage"[^>]*>(.*?)</svg>}m)[1]

    assert_includes styles, '.b270[data-display-mode="sage"] > .b270-theme-scenery[data-scenery="sage_sky"]'
    assert_includes styles, '.b270-theme-scenery[data-scenery="sage_sky"]{height:100%}'
    assert_includes sky, 'fill="url(#b270-meadow-blue-sky)"'
    assert_includes sky, 'stop-color="#bdd8eb"'
    clouds = sky.match(%r{<g id="b270-meadow-clouds"[^>]*>(.*?)</g>}m)[1]
    assert_equal 4, clouds.scan(%r{<path\b}).size
    { 'distant' => 6, 'near' => 11 }.each do |depth, count|
      grass = meadow.match(%r{<g id="b270-meadow-grass-#{depth}"[^>]*>(.*?)</g>}m)[1]
      assert_equal count, grass.scan(%r{<path\b}).size
    end
    assert_includes meadow, 'clip-path="url(#b270-meadow-sky)"'
    assert_includes meadow, '<circle cx="1560" cy="260" r="61"'
  end

  def test_midnight_moon_has_a_static_lake_and_clipped_moonlight_reflection
    scenery = File.read(File.join(VIEW_ROOT, 'bible270/shared/_theme_scenery.html.erb'))
    lake = scenery.match(%r{<svg[^>]*data-scenery="dark_blue"[^>]*>(.*?)</svg>}m)[1]

    assert_match(%r{data-scenery="dark_blue"[^>]*preserveAspectRatio="xMaxYMax slice"}, scenery)
    assert_includes lake, 'id="b270-midnight-moon"'
    assert_includes lake, 'id="b270-lake-shore"'
    assert_includes lake, 'id="b270-lake-reflection" fill="url(#b270-moon-reflection)"'
    assert_includes lake, 'clip-path="url(#b270-lake-clip)"'
    reflection_colour = lake.match(%r{id="b270-moon-reflection"[^>]*>\s*<stop[^>]*stop-color="([^"]+)"})[1]
    assert_includes File.read(STYLES), ".b270[data-display-mode=\"dark_blue\"] > .b270-theme-scripture{color:#{reflection_colour}}"
    refute_match(%r{<(?:image|script|animate)\b}, lake)
    reflected_lines = lake.scan(%r{<text transform="translate\(1510 \d+\) scale\([\d.]+ -[\d.]+\)">(.*?)</text>}).flatten
    assert_equal %w[ΟΛΟΓΟΣ ΘΕΟΣΗΝ ΘΕΟΝΚΑΙ ΗΝΠΡΟΣΤΟΝ ΚΑΙΟΛΟΓΟΣ ΗΝΟΛΟΓΟΣ ΕΝΑΡΧΗ], reflected_lines
    assert_includes lake, 'mask="url(#b270-greek-reflection)"'
    water = lake.match(%r{<g clip-path="url\(#b270-lake-clip\)">(.*?)</g>}m)[1]
    refute_match(%r{<path\b}, water)
  end

  def test_water_reflections_grow_and_soften_towards_the_viewer_with_fainter_hebrew
    styles = File.read(STYLES)
    scenery = File.read(File.join(VIEW_ROOT, 'bible270/shared/_theme_scenery.html.erb'))
    lake = scenery.match(%r{<svg[^>]*data-scenery="dark_blue"[^>]*>(.*?)</svg>}m)[1]
    hebrew = scenery.match(%r{<svg[^>]*data-scenery="hebrew_water"[^>]*>(.*?)</svg>}m)[1]

    scales = lake.scan(%r{translate\(1510 \d+\) scale\(([\d.]+) -[\d.]+\)}).flatten.map(&:to_f)
    assert_equal scales.sort, scales
    assert_operator scales.last / scales.first, :>, 3
    blur = %w[far middle near].map do |depth|
      filter = lake.match(%r{<filter id="b270-water-#{depth}"[^>]*>(.*?)</filter>}m)[1]
      assert_includes filter, '<feTurbulence'
      assert_includes filter, '<feDisplacementMap'
      filter.match(%r{stdDeviation="([\d.]+)"})[1].to_f
    end
    assert_equal blur.sort, blur
    assert_operator blur.last, :>, blur.first
    assert_equal %w[הארץ ואת השּׁמים את אלהים בּרא בּראשׁית], hebrew.scan(%r{<text[^>]*>(.*?)</text>}).flatten
    assert_includes hebrew, 'opacity=".4"'
    assert_includes styles, '.b270-hebrew-water{font-size:max(2vw, var(--b270-scene-height) * 32 / 440);'
    assert_includes hebrew, 'direction="rtl" unicode-bidi="isolate"'
    assert_includes styles, '.b270[data-display-mode="dark_blue"] > .b270-theme-scenery[data-scenery="hebrew_water"]'
  end

  def test_spruce_forest_draws_explicitly_coloured_paths_without_use_instances
    scenery = ERB.new(File.read(File.join(VIEW_ROOT, 'bible270/shared/_theme_scenery.html.erb'))).result
    forest = scenery.match(%r{<svg[^>]*data-scenery="dark_green"[^>]*>(.*?)</svg>}m)[1]

    assert_includes forest, 'id="b270-spruce-distant"'
    assert_includes forest, 'id="b270-spruce-near"'
    assert_includes forest, 'mask="url(#b270-spruce-mask)"'
    assert_equal 60, forest.scan('class="b270-spruce-tree"').size
    refute_match(%r{<(?:use|image|script|animate|text)\b}, forest)
    refute_includes forest, '<%'
    paths = Nokogiri::HTML.fragment(forest).css('path.b270-spruce-tree')
    assert_equal 1, paths.map { |tree| tree['d'] }.uniq.size
    assert_match(%r{\AM0 0.*Z\z}, paths.first['d'])

    artwork = Nokogiri::HTML.fragment(scenery)
    near = artwork.at_css('#b270-spruce-near')
    assert_equal '#0c2017', near['fill']
    ([near] + near.ancestors.to_a).each do |element|
      %w[opacity fill-opacity mask filter].each { |attribute| assert_nil element[attribute] }
    end
    assert_equal 30, near.css('path').size
    heights = near.css('path').map { |tree| tree['transform'].match(%r{scale\([\d.]+ ([\d.]+)\)})[1].to_f }
    assert_operator heights.max / heights.min, :>, 2
    assert_equal 'url(#b270-spruce-mask)', artwork.at_css('#b270-spruce-distant')['mask']
    assert_equal 'translate(0 -24)', artwork.at_css('#b270-spruce-treeline')['transform']
    %w[distant near].each do |depth|
      layer = artwork.at_css("#b270-spruce-#{depth}")
      ground = layer.at_css("rect#b270-spruce-#{depth}-ground")
      assert_equal '1600', ground['width']
      assert_equal 464, ground['y'].to_i + ground['height'].to_i
      assert_equal [layer['fill']], layer.css('path').map { |tree| tree['fill'] }.uniq
      small_trees = layer.css('path').count do |tree|
        tree['transform'].match(%r{scale\([\d.]+ ([\d.]+)\)})[1].to_f < 0.6
      end
      assert_equal 9, small_trees
    end
  end

  def test_cedar_bark_has_local_grain_and_follows_system_dark_appearance
    styles = File.read(STYLES)
    scenery = File.read(File.join(VIEW_ROOT, 'bible270/shared/_theme_scenery.html.erb'))
    cedar = scenery.match(%r{<svg[^>]*data-scenery="dark"[^>]*>(.*?)</svg>}m)[1]

    assert_includes cedar, '<pattern id="b270-cedar-grain"'
    assert_includes cedar, 'fill="url(#b270-cedar-grain)" mask="url(#b270-cedar-mask)"'
    refute_match(%r{<(?:image|script|animate|text)\b}, cedar)
    assert_includes styles, '.b270-theme-scenery[data-scenery="dark"]{height:100%}'
    assert_match(%r{@media \(prefers-color-scheme:dark\)\{\s*\.b270\[data-display-mode="system"\] > \.b270-theme-scenery\[data-scenery="light"\]\{display:none\}\s*\.b270\[data-display-mode="system"\] > \.b270-theme-scenery\[data-scenery="dark"\]\{display:block\}}, styles)
  end

  def test_shared_scripture_preserves_text_and_positions_independently_of_papyrus_grid
    styles = File.read(STYLES)
    scenery = File.read(File.join(VIEW_ROOT, 'bible270/shared/_theme_scenery.html.erb'))
    papyrus = scenery.match(%r{<svg[^>]*data-scenery="light"[^>]*>(.*?)</svg>}m)[1]
    scripture = scenery.match(%r{<svg class="b270-theme-scenery b270-theme-scripture" data-scenery="scripture"[^>]*>(.*?)</svg>}m)[1]
    hebrew = scripture.match(%r{<g lang="he"[^>]*>(.*?)</g>}m)[1]
    greek = scripture.match(%r{<g lang="el"[^>]*>(.*?)</g>}m)[1]
    refute_match(%r{<(?:text|tspan)\b}, papyrus)
    assert_equal 14, scripture.scan(%r{<text\b}).size
    assert_includes scripture, 'fill="currentColor" text-anchor="middle" opacity=".22"'

    hebrew_lines = hebrew.scan(%r{<text[^>]*>(.*?)</text>}).flatten
    greek_lines = greek.scan(%r{<tspan[^>]*>(.*?)</tspan>}).flatten
    assert_equal %w[בּראשׁית בּרא אלהים את השּׁמים ואת הארץ], hebrew_lines
    assert_equal %w[ΕΝΑΡΧΗ ΗΝΟΛΟΓΟΣ ΚΑΙΟΛΟΓΟΣ ΗΝΠΡΟΣΤΟΝ ΘΕΟΝΚΑΙ ΘΕΟΣΗΝ ΟΛΟΓΟΣ], greek_lines
    [hebrew, greek].each do |column|
      assert_equal %w[-3.2em -2em -.8em .4em 1.6em 2.8em 4em], column.scan(%r{dy="([^"]+)"}).flatten
    end
    assert_includes hebrew, '<text x="10%" y="30%" dy="-3.2em">'
    assert_includes greek, '<text y="30%" dy="-3.2em">'

    assert_includes scripture, 'lang="el" direction="ltr" text-anchor="middle"'
    assert_includes styles, '.b270-scripture-letters [lang="el"] tspan{font-size:.9em}'
    assert_includes papyrus, 'width="4em" height="3.6em"'
    assert_includes styles, '.b270-papyrus-grid{transform-box:view-box;transform:translateY(calc(100% - clamp(380px,76vh,820px) * .7))}'
    assert_includes papyrus, 'viewBox="0 0 120 108"'
    assert_includes papyrus, 'd="M0 12H120M0 48H120M0 84H120"'
    assert_includes scripture, 'lang="he" direction="rtl" unicode-bidi="isolate"'
    assert_includes styles, '.b270-theme-scenery[data-scenery="light"],.b270-theme-scripture{font-size:clamp(12px,2.2vw,30px)}'
    assert_includes styles, '.b270-theme-scripture{height:clamp(380px,76vh,820px)}'
    hebrew.scan(%r{<text x="(\d+)%"}).flatten.each { |x| assert_operator x.to_i, :<=, 12 }
    assert_includes styles, '.b270-scripture-letters [lang="el"]{transform-box:view-box;transform:translateX(calc(100% - max(5.625%, var(--b270-scene-height) * 90 / 440)))}'
    assert_includes papyrus, 'fill="url(#b270-papyrus-fibres)"'
    assert_includes styles, '.b270[data-display-mode="system"] > .b270-theme-scenery[data-scenery="light"]{display:block}'
    assert_match(%r{@media \(prefers-color-scheme:dark\)\{\s*\.b270\[data-display-mode="system"\] > \.b270-theme-scenery\[data-scenery="light"\]\{display:none\}}, styles)
  end

  def test_papyrus_has_a_full_page_grid_ragged_edges_and_responsive_curled_corners
    styles = File.read(STYLES)
    scenery = File.read(File.join(VIEW_ROOT, 'bible270/shared/_theme_scenery.html.erb'))
    papyrus = scenery.match(%r{<svg[^>]*data-scenery="light"[^>]*>(.*?)</svg>}m)[1]

    assert_includes styles, '.b270-theme-scenery[data-scenery="light"]{height:100%;overflow:hidden}'
    assert_includes papyrus, '<rect y="-100%" width="100%" height="200%" fill="url(#b270-papyrus-fibres)"'
    refute_includes papyrus, 'b270-papyrus-fade'
    %w[top side].each do |edge|
      assert_equal 2, papyrus.scan("fill=\"url(#b270-papyrus-edge-#{edge})\"").size
    end
    assert_equal 2, papyrus.scan('href="#b270-papyrus-corner"').size
    assert_includes papyrus, 'fill="url(#b270-papyrus-curl)"'
    assert_includes papyrus, 'fill="url(#b270-papyrus-curl-shadow)"'
    assert_includes styles, 'transform:translate(100%,100%) rotate(180deg)'
    assert_match(%r{@media \(max-width:600px\)\{\s*\.b270-papyrus-corner\{transform:scale\(\.55\)\}}, styles)
  end

  def test_system_theme_uses_a_media_query_and_matches_explicit_dark
    styles = File.read(STYLES)
    dark = styles.match(%r{\.b270\[data-display-mode="dark"\]\{([^\}]+)})[1]
    system = styles.match(%r{@media \(prefers-color-scheme:dark\)\{\s*\.b270-reader-theme\[data-display-mode="system"\],\s*\.b270\[data-display-mode="system"\]\{([^\}]+)})[1]

    assert_equal dark.split.join, system.split.join
    assert_includes dark, 'color-scheme:dark'
    assert_includes styles, '.b270[data-display-mode="light"]{color-scheme:only light}'
    assert_match(%r{\.b270-completion-dove\{[^\}]*color-scheme:only light;forced-color-adjust:none}, styles)
  end

private

  def phone_scenery_styles(styles)
    # Match complete media blocks, not just the first nested rule or the separate corner-size block.
    blocks = styles.scan(%r{@media \(max-width:600px\)\{(?:[^{}]|\{[^{}]*\})*\}})
      .select { |block| block.include?('--b270-scene-height:') }
    assert_equal 1, blocks.size, 'expected one phone-scoped scenery block'
    blocks.first
  end

  def scenery_css_rules(styles)
    styles.gsub(%r{/\*.*?\*/}m, '').scan(%r{([^{}]+)\{([^{}]*)\}}).flat_map do |selectors, declarations|
      selectors.split(',').map { |selector| [selector.strip, declarations.strip] }
    end
  end

  def contrast_ratio(first, second)
    lighter, darker = [relative_luminance(first), relative_luminance(second)].sort.reverse
    (lighter + 0.05) / (darker + 0.05)
  end

  def relative_luminance(hex)
    components = hex.scan(%r{..}).map do |pair|
      value = pair.to_i(16) / 255.0
      value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055)**2.4
    end
    (0.2126 * components[0]) + (0.7152 * components[1]) + (0.0722 * components[2])
  end
end
