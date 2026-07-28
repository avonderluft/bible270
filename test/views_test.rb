# frozen_string_literal: true

require 'test_helper'

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
end
