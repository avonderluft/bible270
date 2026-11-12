# frozen_string_literal: true

require 'test_helper'
require 'bible270/scripture_frames'

if RAILS_LOADED
  class ScriptureFramesTest < Minitest::Test
    CATALOG = Bible270::ScriptureFrames
    SUPPLIED_PASSAGES = [
      { id: 'default:deuteronomy-6-6-7', reference: 'Deuteronomy 6:6-7', translation: 'NASB95',
        text: 'These words, which I am commanding you today, shall be on your heart. You shall teach them diligently to your sons and shall talk of them when you sit in your house and when you walk by the way and when you lie down and when you rise up.',
        attribution: 'NASB 1995 © The Lockman Foundation.' },
      { id: 'default:deuteronomy-11-18', reference: 'Deuteronomy 11:18', translation: 'NKJV',
        text: 'Therefore you shall lay up these words of mine in your heart and in your soul, and bind them as a sign on your hand, and they shall be as frontlets between your eyes.',
        attribution: 'NKJV © 1982 Thomas Nelson.' },
      { id: 'default:deuteronomy-30-14', reference: 'Deuteronomy 30:14', translation: 'ESV',
        text: 'But the word is very near you. It is in your mouth and in your heart, so that you can do it.',
        attribution: 'ESV © 2001 Crossway.' },
      { id: 'default:psalm-19-8', reference: 'Psalm 19:8', translation: 'NKJV',
        text: "The statutes of the LORD are right, rejoicing the heart;\nThe commandment of the LORD is pure, enlightening the eyes.",
        attribution: 'NKJV © 1982 Thomas Nelson.' },
      { id: 'default:psalm-107-20', reference: 'Psalm 107:20', translation: 'NKJV',
        text: "He sent His word and healed them,\nAnd delivered them from their destructions.",
        attribution: 'NKJV © 1982 Thomas Nelson.' },
      { id: 'default:psalm-119-11', reference: 'Psalm 119:11', translation: 'NASB95',
        text: "Your word I have treasured in my heart,\nThat I may not sin against You.",
        attribution: 'NASB 1995 © The Lockman Foundation.' },
      { id: 'default:psalm-119-47', reference: 'Psalm 119:47', translation: 'NKJV',
        text: "I will delight myself in Your commandments,\nWhich I love.",
        attribution: 'NKJV © 1982 Thomas Nelson.' },
      { id: 'default:psalm-119-103', reference: 'Psalm 119:103', translation: 'NASB95',
        text: "How sweet are Your words to my taste!\nYes, sweeter than honey to my mouth!",
        attribution: 'NASB 1995 © The Lockman Foundation.' },
      { id: 'default:psalm-119-105', reference: 'Psalm 119:105', translation: 'NKJV',
        text: "Your word is a lamp to my feet\nAnd a light to my path.",
        attribution: 'NKJV © 1982 Thomas Nelson.' },
      { id: 'default:psalm-119-130', reference: 'Psalm 119:130', translation: 'NASB95',
        text: "The unfolding of Your words gives light;\nIt gives understanding to the simple.",
        attribution: 'NASB 1995 © The Lockman Foundation.' },

      { id: 'default:proverbs-6-23', reference: 'Proverbs 6:23', translation: 'NASB95',
        text: "For the commandment is a lamp and the teaching is light;\nAnd reproofs for discipline are the way of life",
        attribution: 'NASB 1995 © The Lockman Foundation.' },
      { id: 'default:isaiah-55-11', reference: 'Isaiah 55:11', translation: 'ESV',
        text: "so shall my word be that goes out from my mouth;\nit shall not return to me empty,\nbut it shall accomplish that which I purpose,\nand shall succeed in the thing for which I sent it.",
        attribution: 'ESV © 2001 Crossway.' },
      { id: 'default:jeremiah-15-16', reference: 'Jeremiah 15:16', translation: 'NASB95',
        text: "Your words were found and I ate them,\nAnd Your words became for me a joy and the delight of my heart;\nFor I have been called by Your name,\nO LORD God of hosts.",
        attribution: 'NASB 1995 © The Lockman Foundation.' },
      { id: 'default:jeremiah-23-29', reference: 'Jeremiah 23:29', translation: 'NKJV',
        text: "“Is not My word like a fire?” says the LORD,\n“And like a hammer that breaks the rock in pieces?",
        attribution: 'NKJV © 1982 Thomas Nelson.' },
      { id: 'default:john-6-63', reference: 'John 6:63', translation: 'NKJV',
        text: 'It is the Spirit who gives life; the flesh profits nothing. The words that I speak to you are spirit, and they are life.',
        attribution: 'NKJV © 1982 Thomas Nelson.' },
      { id: 'default:john-17-17', reference: 'John 17:17', translation: 'NASB95',
        text: '“Sanctify them in the truth; Your word is truth.',
        attribution: 'NASB 1995 © The Lockman Foundation.' },
      { id: 'default:2-corinthians-4-6', reference: '2 Corinthians 4:6', translation: 'NKJV',
        text: 'For it is the God who commanded light to shine out of darkness, who has shone in our hearts to give the light of the knowledge of the glory of God in the face of Jesus Christ.',
        attribution: 'NKJV © 1982 Thomas Nelson.' },
      { id: 'default:colossians-3-16', reference: 'Colossians 3:16', translation: 'ESV',
        text: 'Let the word of Christ dwell in you richly, teaching and admonishing one another in all wisdom, singing psalms and hymns and spiritual songs, with thankfulness in your hearts to God.',
        attribution: 'ESV © 2001 Crossway.' },
      { id: 'default:2-timothy-3-16-17', reference: '2 Timothy 3:16-17', translation: 'ESV',
        text: 'All Scripture is breathed out by God and profitable for teaching, for reproof, for correction, and for training in righteousness, that the man of God may be complete, equipped for every good work.',
        attribution: 'ESV © 2001 Crossway.' },
      { id: 'default:hebrews-4-12', reference: 'Hebrews 4:12', translation: 'NKJV',
        text: 'For the word of God is living and powerful, and sharper than any two-edged sword, piercing even to the division of soul and spirit, and of joints and marrow, and is a discerner of the thoughts and intents of the heart.',
        attribution: 'NKJV © 1982 Thomas Nelson.' },
      { id: 'default:1-peter-2-2-3', reference: '1 Peter 2:2-3', translation: 'NASB95',
        text: 'like newborn babies, long for the pure milk of the word, so that by it you may grow in respect to salvation, if you have tasted the kindness of the Lord.',
        attribution: 'NASB 1995 © The Lockman Foundation.' }
    ].freeze

    def setup
      clear_engine_tables!
      Bible270::ScriptureFrame.delete_all
      @previous_path = Bible270.config.scripture_frames_path
      Bible270.config.scripture_frames_path = nil
      @default_frames = CATALOG.defaults.map(&:dup)
      @default_translations = CATALOG.translations
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

    def test_bundled_catalog_preserves_supplied_passages_and_credits_in_biblical_order
      frames = CATALOG.defaults.index_by(&:id)
      assert_equal SUPPLIED_PASSAGES.map { |entry| entry[:id] }.to_a, frames.keys

      SUPPLIED_PASSAGES.each do |expected|
        assert frames.key?(expected[:id]), "Missing supplied passage #{expected[:id]}"
        assert_equal expected, frames.fetch(expected[:id]).to_h
        assert_includes CATALOG.translations, expected[:translation]
        assert_equal expected[:attribution], CATALOG.attribution_for(expected[:translation].downcase)
      end
    end

    def test_translation_options_follow_reader_preferences_with_extra_choices_last
      assert_equal %w[NKJV NASB95 LSB ESV KJV YLT CSB NIV], CATALOG.translations
      shared = Bible270::Translations.codes & CATALOG.translations
      assert_equal shared, CATALOG.translations.first(shared.length)
      assert_equal SUPPLIED_PASSAGES.length, CATALOG.defaults.length

      Bible270::Translations.stub(:codes, %w[KJV ESV NKJV]) do
        assert_equal %w[KJV ESV NKJV NASB95 LSB YLT CSB NIV], CATALOG.translations
      end
    end

    def test_translation_registry_combines_bundled_and_host_metadata_without_restoring_default_frames
      use_host(YAML.dump([
        host_row(translation: ' host ', attribution: 'Host sample credit.'),
        host_row(id: 'public-example', translation: ' public ')
      ]))

      assert_equal %w[default:host-example default:public-example], CATALOG.defaults.map(&:id)
      assert_equal default_translations + %w[HOST PUBLIC], CATALOG.translations
      @default_frames.each do |frame|
        assert_equal frame.attribution, CATALOG.attribution_for(frame.translation)
      end
      assert_equal 'Host sample credit.', CATALOG.attribution_for(' host ')
      assert CATALOG.translation_attributions.key?('PUBLIC')
      assert_nil CATALOG.attribution_for('PUBLIC')
      assert_nil CATALOG.attribution_for('UNKNOWN')
    end

    def test_host_frames_in_known_translations_can_inherit_bundled_credit
      use_host(YAML.dump([host_row(translation: ' nkjv ')]))

      assert_equal ['default:host-example'], CATALOG.defaults.map(&:id)
      assert_equal 'NKJV', CATALOG.defaults.first.translation
      assert_equal 'NKJV © 1982 Thomas Nelson.', CATALOG.defaults.first.attribution
      assert_equal 'NKJV © 1982 Thomas Nelson.', CATALOG.attribution_for('NKJV')
    end

    def test_empty_host_catalog_keeps_known_translation_metadata
      use_host("[]\n")

      assert_empty CATALOG.defaults
      assert_equal default_translations, CATALOG.translations
    end

    def test_conflicting_translation_credits_fall_back_instead_of_mislabeling
      [
        [host_row(translation: 'nasb95', attribution: 'Wrong credit.')],
        [host_row(translation: 'TEST', attribution: 'One credit.'),
         host_row(id: 'another-example', translation: ' test ', attribution: 'Another credit.')]
      ].each do |rows|
        use_host(YAML.dump(rows))
        assert_equal @default_frames.map(&:to_h), CATALOG.defaults.map(&:to_h)
        assert_equal 'NASB 1995 © The Lockman Foundation.', CATALOG.attribution_for('NASB95')
      end
    end

    def test_creating_custom_frames_does_not_write_yaml_or_remove_defaults
      bundled = File.expand_path('../config/scripture_frames.yml', __dir__)
      original = File.binread(bundled)
      custom = Bible270::ScriptureFrame.create!(reference: 'Custom example', text: 'Sample text.', translation: 'NKJV')

      assert_equal original, File.binread(bundled)
      assert_equal @default_frames.map(&:to_h), CATALOG.defaults.map(&:to_h)
      assert_equal 'NKJV © 1982 Thomas Nelson.', custom.reload.attribution
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

    def test_catalog_is_read_lazily_without_a_stale_cache
      use_host(YAML.dump([host_row]))
      assert_equal 'Host example', CATALOG.defaults.first.reference
      assert_nil CATALOG.attribution_for('TEST')

      File.write(Bible270.config.scripture_frames_path, YAML.dump([host_row(reference: 'Updated example', attribution: 'Updated credit.')]))
      assert_equal 'Updated example', CATALOG.defaults.first.reference
      assert_equal 'Updated credit.', CATALOG.attribution_for('TEST')
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
          assert_equal @default_frames.map(&:to_h), CATALOG.defaults.map(&:to_h)
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
        assert_equal @default_frames.map(&:to_h), CATALOG.defaults.map(&:to_h)
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
        assert_equal default_ids, CATALOG.defaults.map(&:id)
      end
      use_host(YAML.dump([host_row, host_row]))
      assert_equal default_ids, CATALOG.defaults.map(&:id)
      use_host(YAML.dump({ 'frames' => [] }))
      assert_equal default_ids, CATALOG.defaults.map(&:id)
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
        Bible270::Setting.write(disable_key(default_ids[index + 1]), value)
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
      bundled_id = default_ids.first
      CATALOG.set_default_enabled!(bundled_id, enabled: false)
      use_host(YAML.dump([host_row]))
      assert_raises(ArgumentError) { CATALOG.set_default_enabled!(bundled_id, enabled: true) }
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

      Bible270.config.scripture_frames_path = nil
      CATALOG.stub(:defaults, [@default_frames.first]) { assert_nil CATALOG.random }
      assert_includes CATALOG.disabled_default_ids, bundled_id
      CATALOG.set_default_enabled!(bundled_id, enabled: true)
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
      assert CATALOG.custom_available?
      Bible270::ScriptureFrame.stub(:table_exists?, false) do
        Bible270::ScriptureFrame.stub(:enabled, -> { flunk 'must not query a missing table' }) do
          refute CATALOG.custom_available?
          assert_equal @default_frames.map(&:to_h), CATALOG.defaults.map(&:to_h)
          assert_includes @default_frames.map(&:to_h), CATALOG.random.to_h
        end
      end
    end
  end
end
