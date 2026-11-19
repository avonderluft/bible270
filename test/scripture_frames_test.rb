# frozen_string_literal: true

require 'test_helper'
require 'bible270/scripture_frames'
require_relative 'support/scripture_frame_fixtures'

if RAILS_LOADED
  class ScriptureFramesTest < Minitest::Test
    CATALOG = Bible270::ScriptureFrames

    def setup
      clear_engine_tables!
      Bible270::ScriptureFrame.delete_all
      @previous_path = Bible270.config.scripture_frames_path
      Bible270.config.scripture_frames_path = nil
      @bundled_frames = CATALOG.defaults.map(&:dup)
      @bundled_attributions = CATALOG.translation_attributions
      @default_translations = CATALOG.translations
      Bible270.config.scripture_frames_path = ScriptureFrameFixtures::CATALOG_PATH
      @default_frames = CATALOG.defaults.map(&:dup)
      @directory = Dir.mktmpdir('scripture-frames')
    end

    def teardown
      Bible270.config.scripture_frames_path = @previous_path
      Bible270::ScriptureFrame.delete_all
      FileUtils.rm_rf(@directory)
    end

    def default_ids
      @default_frames.map(&:id)
    end

    def disable_key(id)
      "scripture-frame-disabled:#{id}"
    end

    attr_reader :default_translations

    def host_row(**overrides)
      { 'id' => 'host-example', 'reference' => 'Host example', 'translation' => 'TEST',
        'text' => "First sample line.\nSecond sample line." }.merge(overrides.transform_keys(&:to_s))
    end

    def use_host(source)
      path = File.join(@directory, 'frames.yml')
      File.write(path, source)
      Bible270.config.scripture_frames_path = path
    end

    def test_translation_options_follow_reader_preferences_with_extra_choices_last
      use_host(YAML.dump([
        host_row(translation: 'ZZZHOST', attribution: 'Last host credit.'),
        host_row(id: 'another-example', translation: 'AAAHOST')
      ]))
      available = CATALOG.translation_attributions.keys
      reader_versions = Bible270::Translations::VERSIONS.keys & available
      additional_versions = CATALOG.const_get(:ADDITIONAL_ATTRIBUTIONS).keys
      built_in_versions = (reader_versions + additional_versions).uniq & available
      preferred = Bible270::Translations.codes & available
      remaining = built_in_versions - preferred
      extras = available - built_in_versions
      assert_equal preferred + remaining + extras.sort, CATALOG.translations
      assert_equal %w[AAAHOST ZZZHOST], (CATALOG.translations & %w[AAAHOST ZZZHOST])

      preference = reader_versions.reverse.first(3)
      Bible270::Translations.stub(:codes, preference) do
        assert_equal preference + (built_in_versions - preference) + extras.sort, CATALOG.translations
      end
    end

    def test_other_quotation_is_an_extra_form_option_not_a_bible_translation
      assert_equal CATALOG.translations.map { |code| [code, code] } + [['Other quotation', 'OTHER']], CATALOG.translation_options
      refute_includes CATALOG.translations, 'OTHER'
      assert CATALOG.quotation?(' other ')
      refute CATALOG.quotation?('NASB95')
      assert_nil CATALOG.attribution_for('OTHER')
    end

    def test_biblical_order_uses_books_then_numeric_chapters_and_verses_with_stable_ties
      references = ['Revelation 1:1', 'Psalm 119:103', 'John 3:16', 'Genesis 1:1', 'Psa 119.11',
                    'Deut. 6.6-7', '2 Timothy 3:16-17', 'John 3:2', 'John 3:2', 'PsALms 2:1', 'Jhn 6:63']
      frames = references.each_with_index.map { |reference, id| CATALOG::Entry.new(id: id, reference: reference, translation: 'ESV') }
      quote = CATALOG::Entry.new(id: 'quote', reference: 'Genesis 1:1', translation: 'OTHER')
      unknown = CATALOG::Entry.new(id: 'unknown', reference: 'An unrecognized reference', translation: 'ESV')

      sorted = CATALOG.in_biblical_order([quote, unknown, *frames])
      assert_equal [3, 5, 9, 4, 1, 7, 8, 2, 10, 6, 0, 'unknown', 'quote'], sorted.map(&:id)
      assert_empty CATALOG.in_biblical_order([])
    end

    def test_enabled_other_quotations_join_the_random_pool_without_bible_credits
      use_host("[]\n")
      quote = Bible270::ScriptureFrame.create!(reference: 'An author', text: 'A quotation.', translation: 'OTHER')
      selected = CATALOG.random
      assert_equal "custom:#{quote.id}", selected.id
      assert_equal 'An author', selected.reference
      assert_nil selected.attribution
      quote.update!(enabled: false)
      assert_nil CATALOG.random
    end

    def test_translation_registry_combines_bundled_and_host_metadata_without_restoring_default_frames
      use_host(YAML.dump([
        host_row(translation: ' host ', attribution: 'Host sample credit.'),
        host_row(id: 'public-example', translation: ' public ')
      ]))

      assert_equal %w[default:host-example default:public-example], CATALOG.defaults.map(&:id)
      assert_equal (default_translations + %w[HOST PUBLIC]).sort, CATALOG.translations.sort
      assert_equal @bundled_attributions, CATALOG.translation_attributions.except('HOST', 'PUBLIC')
      assert_equal 'Host sample credit.', CATALOG.attribution_for(' host ')
      assert CATALOG.translation_attributions.key?('PUBLIC')
      assert_nil CATALOG.attribution_for('PUBLIC')
      assert_nil CATALOG.attribution_for('UNKNOWN')
    end

    def test_host_frames_in_known_translations_can_inherit_bundled_credit
      code = @bundled_frames.first.translation
      credit = @bundled_attributions.fetch(code)
      use_host(YAML.dump([host_row(translation: " #{code.downcase} ")]))

      assert_equal ['default:host-example'], CATALOG.defaults.map(&:id)
      assert_equal [code, credit], [CATALOG.defaults.first.translation, CATALOG.defaults.first.attribution]
      assert_equal({ code => credit }, CATALOG.translation_attributions.slice(code))
    end

    def test_empty_host_catalog_keeps_known_translation_metadata
      use_host("[]\n")

      assert_empty CATALOG.defaults
      assert_equal default_translations, CATALOG.translations
    end

    def test_conflicting_translation_credits_fall_back_instead_of_mislabeling
      code, credit = @bundled_attributions.find { |_, attribution| attribution }
      [
        [host_row(translation: code.downcase, attribution: "#{credit} Conflicting credit.")],
        [host_row(translation: 'TEST', attribution: 'One credit.'),
         host_row(id: 'another-example', translation: ' test ', attribution: 'Another credit.')]
      ].each do |rows|
        use_host(YAML.dump(rows))
        assert_equal @bundled_frames.map(&:to_h), CATALOG.defaults.map(&:to_h)
        assert_equal credit, CATALOG.attribution_for(code)
      end
    end

    def test_creating_custom_frames_does_not_write_yaml_or_remove_defaults
      bundled = File.expand_path('../config/scripture_frames.yml', __dir__)
      original = File.binread(bundled)
      credit = CATALOG.attribution_for('NKJV')
      custom = Bible270::ScriptureFrame.create!(reference: 'Custom example', text: 'Sample text.', translation: 'NKJV')

      assert_equal original, File.binread(bundled)
      assert_equal @default_frames.map(&:to_h), CATALOG.defaults.map(&:to_h)
      assert_equal [credit], [custom.reload.attribution]
      assert_includes default_ids, CATALOG.random(exclude: "custom:#{custom.id}").id
      custom.destroy!
      default_ids.each do |previous|
        assert_includes default_ids - [previous], CATALOG.random(exclude: previous).id
      end
    end

    def test_custom_creation_never_rewrites_host_yaml
      use_host(YAML.dump([host_row(translation: 'HOST', attribution: 'Host sample credit.')]))
      original = File.binread(Bible270.config.scripture_frames_path)
      custom = Bible270::ScriptureFrame.create!(reference: 'Custom example', text: 'Sample text.', translation: 'HOST')

      assert_equal original, File.binread(Bible270.config.scripture_frames_path)
      assert_equal 'Host sample credit.', custom.reload.attribution
      assert_equal ['default:host-example'], CATALOG.defaults.map(&:id)
    end

    def test_host_yaml_replaces_rather_than_appends_defaults_and_preserves_plaintext
      row = host_row(text: "A <b>sample</b> & text.\nAnother line.")
      use_host(YAML.dump([row]))

      assert_equal 1, CATALOG.defaults.length
      frame = CATALOG.defaults.first
      assert_equal 'default:host-example', frame.id
      assert_equal row['text'], frame.text
      assert_nil frame.attribution
    end

    def test_host_yaml_normalizes_fields_without_changing_plaintext_contents
      use_host(YAML.dump([host_row(reference: "  John 1:1\r\n ", translation: ' test ',
                                   text: "  A <b>sample</b> & \"quoted\" text.\r\nAnother line.  ",
                                   attribution: "  Host credit.\r\nSecond credit line.  ")]))

      assert_equal({ id: 'default:host-example', reference: 'John 1:1', translation: 'TEST',
                     text: "A <b>sample</b> & \"quoted\" text.\nAnother line.",
                     attribution: "Host credit.\nSecond credit line." }, CATALOG.defaults.first.to_h)
      use_host(YAML.dump([host_row(attribution: " \r\n ")]))
      assert_nil CATALOG.defaults.first.attribution
    end

    def test_catalog_is_read_lazily_after_valid_additions_removals_and_text_edits
      use_host(YAML.dump([host_row]))
      assert_equal 'Host example', CATALOG.defaults.first.reference
      assert_nil CATALOG.attribution_for('TEST')

      edited = host_row(reference: 'Updated example', text: "Updated text.\nSecond line.", attribution: 'Updated credit.')
      added = host_row(id: 'added-example', attribution: 'Updated credit.')
      File.write(Bible270.config.scripture_frames_path, YAML.dump([edited, added]))
      assert_equal %w[default:host-example default:added-example], CATALOG.defaults.map(&:id)
      assert_equal 'Updated example', CATALOG.defaults.first.reference
      assert_equal edited['text'], CATALOG.defaults.first.text
      assert_equal 'Updated credit.', CATALOG.attribution_for('TEST')

      File.write(Bible270.config.scripture_frames_path, YAML.dump([added]))
      assert_equal ['default:added-example'], CATALOG.defaults.map(&:id)
      assert_equal added['text'], CATALOG.defaults.first.text
    end

    def test_empty_host_catalog_is_intentional_and_can_produce_an_empty_pool
      use_host("[]\n")

      assert_empty CATALOG.defaults
      assert_nil CATALOG.random
    end

    def test_unsafe_yaml_and_erb_fall_back_without_evaluation_or_disclosing_input
      sources = [
        '--- !ruby/object:Object {}',
        "- &private_anchor {id: private}\n- *private_anchor\n",
        YAML.dump([host_row(text: '<%= raise "private content must never execute" %>')]),
        "private: [unterminated\n"
      ]
      sources.each do |source|
        use_host(source)
        log = StringIO.new
        Rails.stub(:logger, Logger.new(log)) do
          assert_equal @bundled_frames.map(&:to_h), CATALOG.defaults.map(&:to_h)
        end
        assert_includes log.string, 'using bundled defaults'
        refute_includes log.string, 'private'
        refute_includes log.string, @directory
      end
    end

    def test_missing_file_falls_back_with_a_safe_warning
      Bible270.config.scripture_frames_path = File.join(@directory, 'missing.yml')
      log = StringIO.new
      Rails.stub(:logger, Logger.new(log)) do
        assert_equal @bundled_frames.map(&:to_h), CATALOG.defaults.map(&:to_h)
      end
      assert_includes log.string, 'using bundled defaults'
      refute_includes log.string, @directory
    end

    def test_every_entry_is_validated_and_invalid_catalogs_are_not_partially_loaded
      invalid_rows = [
        host_row(id: 'not a slug'), host_row(reference: ' '), host_row(text: nil),
        host_row(translation: 95), host_row(attribution: []), host_row(unknown: 'field'),
        host_row(reference: 'r' * 201), host_row(text: 'x' * 4001),
        host_row(translation: 't' * 41), host_row(attribution: 'a' * 501), 'not a mapping'
      ]
      invalid_rows.each do |row|
        use_host(YAML.dump([host_row, row]))
        assert_equal @bundled_frames.map(&:to_h), CATALOG.defaults.map(&:to_h)
      end
      use_host(YAML.dump([host_row, host_row]))
      assert_equal @bundled_frames.map(&:to_h), CATALOG.defaults.map(&:to_h)
      use_host(YAML.dump({ 'frames' => [] }))
      assert_equal @bundled_frames.map(&:to_h), CATALOG.defaults.map(&:to_h)
    end

    def test_random_combines_defaults_and_enabled_custom_entries_and_excludes_previous_id
      custom = Bible270::ScriptureFrame.create!(reference: 'Custom example', text: 'Sample text.')
      Bible270::ScriptureFrame.create!(reference: 'Disabled example', text: 'Hidden sample.', enabled: false)
      ids = default_ids + ["custom:#{custom.id}"]

      ids.each do |previous|
        5.times { assert_includes ids - [previous], CATALOG.random(exclude: previous).id }
      end
      10.times { assert_includes ids, CATALOG.random.id }

      # With a one-frame host catalog, each source can be selected deterministically.
      use_host(YAML.dump([host_row]))
      assert_equal "custom:#{custom.id}", CATALOG.random(exclude: 'default:host-example').id
      assert_equal 'default:host-example', CATALOG.random(exclude: "custom:#{custom.id}").id
    end

    def test_rotation_refreshes_enabled_custom_and_default_frames_after_every_catalog_change
      use_host(YAML.dump([host_row(id: 'one'), host_row(id: 'two')]))
      custom = Bible270::ScriptureFrame.create!(reference: 'Quotation', translation: 'OTHER', text: 'A quotation.')
      session = {}
      ids = ['default:one', 'default:two', "custom:#{custom.id}"]
      choose = -> { CATALOG.random(session: session) }
      assert_equal ids.sort, Array.new(3) { choose.call.id }.sort

      CATALOG.set_default_enabled!('default:one', enabled: false)
      custom.update!(enabled: false)
      3.times { assert_equal 'default:two', choose.call.id }
      custom.update!(enabled: true)
      assert_equal "custom:#{custom.id}", choose.call.id, 're-enabled frames enter a fresh cycle without repeating last'
      assert_equal 'OTHER', custom.translation
      custom.destroy!
      assert_equal 'default:two', choose.call.id
      CATALOG.set_default_enabled!('default:one', enabled: true)
      assert_equal 'default:one', choose.call.id
      added = Bible270::ScriptureFrame.create!(reference: 'New quotation', translation: 'OTHER', text: 'New text.')
      selected = Array.new(3) { choose.call.id }
      refute_equal 'default:one', selected.first
      assert_equal ['default:one', 'default:two', "custom:#{added.id}"].sort, selected.sort
      CATALOG.set_default_enabled!('default:one', enabled: false)
      CATALOG.set_default_enabled!('default:two', enabled: false)
      added.destroy!
      assert_nil choose.call
    end

    def test_host_catalog_reordering_preserves_rotation_but_added_and_removed_ids_refresh_it
      rows = [host_row(id: 'one'), host_row(id: 'two'), host_row(id: 'three')]
      use_host(YAML.dump(rows))
      session = {}
      first = CATALOG.random(session: session).id
      state = JSON.parse(JSON.generate(session))
      use_host(YAML.dump(rows.reverse))
      second = CATALOG.random(session: session).id
      use_host(YAML.dump(rows))
      assert_equal second, CATALOG.random(session: state).id
      assert_equal 2, [first, second].uniq.length
      use_host(YAML.dump([rows.first]))
      assert_equal 'default:one', CATALOG.random(session: session).id
      use_host(YAML.dump(rows))
      refute_equal 'default:one', CATALOG.random(session: session).id
    end

    def test_rotation_works_without_settings_or_custom_tables
      Bible270::Setting.stub(:table_exists?, false) do
        Bible270::ScriptureFrame.stub(:table_exists?, false) do
          session = {}
          ids = Array.new(default_ids.length) { CATALOG.random(session: session).id }
          assert_equal default_ids.sort, ids.sort
        end
      end
    end

    def test_custom_pool_uses_current_credit_including_nil_and_preserves_credit_after_translation_removal
      use_host(YAML.dump([host_row(attribution: 'Original credit.')]))
      custom = Bible270::ScriptureFrame.create!(reference: 'Custom example', text: 'Sample text.', translation: 'TEST')

      use_host(YAML.dump([host_row(attribution: 'Revised credit.')]))
      selected = CATALOG.random(exclude: 'default:host-example')
      assert_equal "custom:#{custom.id}", selected.id
      assert_equal 'Revised credit.', selected.attribution

      use_host(YAML.dump([host_row]))
      assert_nil CATALOG.random(exclude: 'default:host-example').attribution

      use_host("[]\n")
      assert_equal 'Original credit.', CATALOG.random.attribution
      custom.update!(enabled: false)
      assert_nil CATALOG.random
    end

    def test_sole_entry_is_returned_even_when_excluded
      use_host(YAML.dump([host_row]))
      assert_equal 'default:host-example', CATALOG.random(exclude: 'default:host-example').id
      use_host("[]\n")
      custom = Bible270::ScriptureFrame.create!(reference: 'Custom example', text: 'Sample text.')
      assert_equal "custom:#{custom.id}", CATALOG.random(exclude: "custom:#{custom.id}").id
    end

    def test_non_string_exclusions_are_ignored
      [[], {}, 12, nil].each do |exclude|
        assert_includes default_ids, CATALOG.random(exclude: exclude).id
      end
    end

    def test_defaults_are_enabled_without_settings_and_enabling_removes_the_disable_record
      assert CATALOG.default_settings_available?
      assert_empty CATALOG.disabled_default_ids
      assert_empty Bible270::Setting.all

      id = default_ids.first
      CATALOG.set_default_enabled!(id, enabled: true)
      assert_empty Bible270::Setting.all
      2.times { CATALOG.set_default_enabled!(id, enabled: false) }
      assert_equal [id], CATALOG.disabled_default_ids
      assert_equal 'true', Bible270::Setting.read(disable_key(id))
      assert_equal 1, Bible270::Setting.count

      CATALOG.set_default_enabled!(id, enabled: true)
      assert_empty CATALOG.disabled_default_ids
      assert_empty Bible270::Setting.all
      assert_equal @default_frames.map(&:to_h), CATALOG.defaults.map(&:to_h)
      assert_empty Bible270::ScriptureFrame.all
    end

    def test_default_toggles_validate_current_ids_and_exact_boolean_values_without_writing
      [nil, 1, [], {}, :default, 'default:unknown', default_ids.first.delete_prefix('default:'), 'custom:1'].each do |id|
        assert_raises(ArgumentError) { CATALOG.set_default_enabled!(id, enabled: false) }
      end
      [nil, 0, 1, 'true', 'false', [], {}].each do |enabled|
        error = assert_raises(ArgumentError) { CATALOG.set_default_enabled!(default_ids.first, enabled: enabled) }
        assert_equal 'enabled must be true or false', error.message
      end
      assert_empty Bible270::Setting.all
      assert_empty Bible270::ScriptureFrame.all
    end

    def test_disabled_ids_use_one_scoped_query_and_ignore_malformed_keys_and_values
      first, second = default_ids.first(2)
      Bible270::Setting.write(disable_key(first), 'true')
      [nil, '', 'false', 'TRUE', '1', '["default:unknown"]'].each_with_index do |value, index|
        Bible270::Setting.write(disable_key("default:malformed-value-#{index}"), value)
      end
      ['custom:1', 'default:bad_slug', 'default:Bad', 'default:', 'default:bad--slug', 'default:valid\n'].each do |id|
        Bible270::Setting.write(disable_key(id), 'true')
      end
      Bible270::Setting.write('scripture_frame_disabled:default:unrelated', 'true')
      Bible270::Setting.write('unrelated-setting', 'true')
      queries = []
      subscriber = ->(*, payload) do
        sql = payload[:sql]
        queries << sql if sql.match?(%r{\ASELECT\b}i) && sql.include?('bible270_settings')
      end
      Bible270::Setting.uncached do
        ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
          assert_equal [first], CATALOG.disabled_default_ids
        end
      end
      assert_equal 1, queries.length
      assert_match(%r{\bWHERE\b.*\bLIKE\b}i, queries.first)

      CATALOG.set_default_enabled!(second, enabled: false)
      assert_equal [first, second].sort, CATALOG.disabled_default_ids.sort
      CATALOG.set_default_enabled!(first, enabled: true)
      assert_equal [second], CATALOG.disabled_default_ids
      assert_equal 'true', Bible270::Setting.read('unrelated-setting')
    end

    def test_interleaved_default_creations_do_not_overwrite_other_ids
      first, second = default_ids.first(2)
      create = Bible270::Setting.method(:create_or_find_by!)
      interleave = ->(**attributes, &block) do
        CATALOG.set_default_enabled!(second, enabled: false) if attributes[:key] == disable_key(first)
        create.call(**attributes, &block)
      end
      Bible270::Setting.stub(:create_or_find_by!, interleave) do
        CATALOG.set_default_enabled!(first, enabled: false)
      end
      assert_equal [first, second].sort, CATALOG.disabled_default_ids.sort
      CATALOG.set_default_enabled!(first, enabled: true)
      assert_equal [second], CATALOG.disabled_default_ids
    end

    def test_concurrent_creation_handles_a_winner_seen_by_the_uniqueness_validator
      id = default_ids.first
      create = Bible270::Setting.method(:create_or_find_by!)
      competing_create = ->(**attributes, &block) do
        Bible270::Setting.create!(**attributes, value: 'false')
        create.call(**attributes, &block)
      end
      Bible270::Setting.stub(:create_or_find_by!, competing_create) do
        CATALOG.set_default_enabled!(id, enabled: false)
      end
      assert_equal [id], CATALOG.disabled_default_ids
      assert_equal 1, Bible270::Setting.count
    end

    def test_concurrent_creation_uses_rails_unique_constraint_recovery
      id = default_ids.first
      Bible270::Setting.create!(key: disable_key(id), value: 'false')
      competing_create = ->(*) { raise ActiveRecord::RecordNotUnique, 'simulated concurrent insert' }
      Bible270::Setting.stub(:find_by, nil) do
        Bible270::Setting.stub(:create!, competing_create) do
          CATALOG.set_default_enabled!(id, enabled: false)
        end
      end
      assert_equal [id], CATALOG.disabled_default_ids
      assert_equal 1, Bible270::Setting.count
    end

    def test_disabled_defaults_are_filtered_before_custom_entries_and_exclusion
      use_host(YAML.dump([host_row, host_row(id: 'another-example')]))
      custom = Bible270::ScriptureFrame.create!(reference: 'Host example', text: 'Independent custom text.', translation: 'TEST')
      Bible270::ScriptureFrame.create!(reference: 'Disabled custom example', text: 'Hidden text.', enabled: false)
      CATALOG.set_default_enabled!('default:host-example', enabled: false)

      assert_equal "custom:#{custom.id}", CATALOG.random(exclude: 'default:another-example').id
      assert_equal 'default:another-example', CATALOG.random(exclude: "custom:#{custom.id}").id
      assert_equal ['default:host-example'], CATALOG.disabled_default_ids
      CATALOG.set_default_enabled!('default:another-example', enabled: false)
      assert_equal "custom:#{custom.id}", CATALOG.random(exclude: "custom:#{custom.id}").id
      assert custom.reload.enabled?
      custom.update!(enabled: false)
      assert_nil CATALOG.random(exclude: 'default:host-example')

      CATALOG.set_default_enabled!('default:host-example', enabled: true)
      assert_equal 'default:host-example', CATALOG.random(exclude: 'default:host-example').id
      refute custom.reload.enabled?
    end

    def test_toggles_leave_frozen_entries_yaml_metadata_and_custom_storage_untouched
      bundled_path = File.expand_path('../config/scripture_frames.yml', __dir__)
      bundled_source = File.binread(bundled_path)
      use_host(YAML.dump([host_row(attribution: 'Host credit.')]))
      host_source = File.binread(Bible270.config.scripture_frames_path)
      metadata = CATALOG.translation_attributions
      frames = CATALOG.defaults.each(&:freeze).freeze
      CATALOG.stub(:defaults, frames) do
        CATALOG.set_default_enabled!(frames.first.id, enabled: false)
        assert_nil CATALOG.random
        assert_equal frames, CATALOG.defaults
        assert_equal metadata, CATALOG.translation_attributions
        CATALOG.set_default_enabled!(frames.first.id, enabled: true)
        assert_equal frames.first.to_h, CATALOG.random.to_h
      end
      assert_equal bundled_source, File.binread(bundled_path)
      assert_equal host_source, File.binread(Bible270.config.scripture_frames_path)
      assert_equal %i[id reference translation text attribution], CATALOG::Entry.members
      assert_empty Bible270::ScriptureFrame.all
    end

    def test_host_catalog_state_follows_stable_ids_across_reloads_removal_and_reintroduction
      fixture_id = default_ids.first
      CATALOG.set_default_enabled!(fixture_id, enabled: false)
      use_host(YAML.dump([host_row]))
      assert_raises(ArgumentError) { CATALOG.set_default_enabled!(fixture_id, enabled: true) }
      assert_equal 'default:host-example', CATALOG.random.id
      CATALOG.set_default_enabled!('default:host-example', enabled: false)
      assert_nil CATALOG.random

      use_host(YAML.dump([host_row(reference: 'Corrected reference', text: 'Corrected text.'), host_row(id: 'new-example')]))
      assert_equal %w[default:host-example default:new-example], CATALOG.defaults.map(&:id)
      assert_equal 'default:new-example', CATALOG.random.id
      use_host("[]\n")
      assert_raises(ArgumentError) { CATALOG.set_default_enabled!('default:host-example', enabled: true) }
      use_host(YAML.dump([host_row]))
      Bible270::Setting.reset_column_information
      assert_nil CATALOG.random

      Bible270.config.scripture_frames_path = ScriptureFrameFixtures::CATALOG_PATH
      CATALOG.stub(:defaults, [@default_frames.first]) { assert_nil CATALOG.random }
      assert_includes CATALOG.disabled_default_ids, fixture_id
      CATALOG.set_default_enabled!(fixture_id, enabled: true)
      assert_equal ['default:host-example'], CATALOG.disabled_default_ids
    end

    def test_default_settings_persist_across_run_restarts_and_reverts_including_changes_after_restart
      first, second = default_ids.first(2)
      CATALOG.set_default_enabled!(first, enabled: false)
      original = Bible270::PlanRun.current
      fresh = Bible270::PlanRun.restart!(start_date: Bible270.today, expected_run_id: original.id)
      assert_equal [first], CATALOG.disabled_default_ids
      CATALOG.set_default_enabled!(first, enabled: true)
      CATALOG.set_default_enabled!(second, enabled: false)
      restored = Bible270::PlanRun.revert!(expected_run_id: fresh.id)
      assert_equal original.id, restored.id
      assert_equal [second], CATALOG.disabled_default_ids
      assert fresh.reload.reverted_at
      assert_equal 2, Bible270::PlanRun.count
      assert_empty Bible270::ScriptureFrame.all
    end

    def test_defaults_remain_enabled_before_settings_table_exists_and_writes_fail_actionably
      Bible270::Setting.stub(:table_exists?, false) do
        Bible270::Setting.stub(:where, ->(*) { flunk 'must not query a missing settings table' }) do
          refute CATALOG.default_settings_available?
          assert_empty CATALOG.disabled_default_ids
          assert_equal @default_frames.map(&:to_h), CATALOG.defaults.map(&:to_h)
          assert_includes default_ids, CATALOG.random.id
          [true, false].each do |enabled|
            error = assert_raises(ArgumentError) { CATALOG.set_default_enabled!(default_ids.first, enabled: enabled) }
            assert_match(%r{database.*migrations}i, error.message)
          end
        end
      end
    end

    def test_default_settings_are_safe_without_a_database_or_connection
      [ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid].each do |exception|
        unavailable = -> { raise exception, 'private database details' }
        Bible270::Setting.stub(:table_exists?, unavailable) do
          refute CATALOG.default_settings_available?
          assert_empty CATALOG.disabled_default_ids
          error = assert_raises(ArgumentError) { CATALOG.set_default_enabled!(default_ids.first, enabled: false) }
          refute_includes error.message, 'private'
        end
        Bible270::Setting.stub(:where, ->(*) { unavailable.call }) { assert_empty CATALOG.disabled_default_ids }
        { where: true, find_by: false }.each do |method, enabled|
          Bible270::Setting.stub(method, ->(*) { unavailable.call }) do
            error = assert_raises(ArgumentError) { CATALOG.set_default_enabled!(default_ids.first, enabled: enabled) }
            assert_match(%r{database.*migrations}i, error.message)
            refute_includes error.message, 'private'
          end
        end
      end
      Bible270::ScriptureFrame.stub(:table_exists?, false) do
        Bible270::Setting.stub(:table_exists?, -> { raise ActiveRecord::NoDatabaseError }) do
          assert_includes default_ids, CATALOG.random.id
        end
      end
    end

    def test_bundled_defaults_work_before_the_custom_table_exists
      Bible270.config.scripture_frames_path = nil
      assert CATALOG.custom_available?
      Bible270::ScriptureFrame.stub(:table_exists?, false) do
        Bible270::ScriptureFrame.stub(:enabled, -> { flunk 'must not query a missing table' }) do
          refute CATALOG.custom_available?
          assert_equal @bundled_frames.map(&:to_h), CATALOG.defaults.map(&:to_h)
          assert_includes @bundled_frames.map(&:to_h), CATALOG.random.to_h
        end
      end
    end
  end
end
