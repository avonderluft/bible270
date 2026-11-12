# frozen_string_literal: true

require 'test_helper'
require 'bible270/scripture_frames'

if RAILS_LOADED
  class ScriptureFrameTest < Minitest::Test
    def setup
      clear_engine_tables!
      Bible270::ScriptureFrame.delete_all
      @previous_path = Bible270.config.scripture_frames_path
      Bible270.config.scripture_frames_path = nil
      @directory = Dir.mktmpdir('scripture-frame-model')
    end

    def teardown
      Bible270.config.scripture_frames_path = @previous_path
      Bible270::ScriptureFrame.delete_all
      FileUtils.rm_rf(@directory)
    end

    def frame(**attributes)
      Bible270::ScriptureFrame.new(reference: 'Example reference', text: 'Sample text.', **attributes)
    end

    def use_host_translation(code: 'HOST', attribution: nil)
      path = File.join(@directory, 'frames.yml')
      File.write(path, YAML.dump([{ 'id' => 'host-example', 'reference' => 'Host example',
                                    'text' => 'Sample text.', 'translation' => code, 'attribution' => attribution }]))
      Bible270.config.scripture_frames_path = path
    end

    def test_defaults_and_persistence_include_automatic_attribution
      record = frame
      assert record.enabled?
      assert_equal 'NASB95', record.translation
      record.save!

      stored = Bible270::ScriptureFrame.find(record.id)
      assert_equal 'Example reference', stored.reference
      assert_equal 'Sample text.', stored.text
      assert_equal 'NASB 1995 © The Lockman Foundation.', stored.attribution
      assert stored.created_at
      assert stored.updated_at
      assert_includes Bible270::ScriptureFrame.enabled, stored
    end

    def test_normalization_preserves_internal_newlines_and_plaintext
      record = frame(reference: " Example reference \r\n", text: " \r\nFirst <b>sample</b>.\r\nSecond & sample.\r\n ",
                     translation: ' nkjv ')
      record.save!
      record.reload

      assert_equal 'Example reference', record.reference
      assert_equal "First <b>sample</b>.\nSecond & sample.", record.text
      assert_equal 'NKJV', record.translation
      assert_equal 'NKJV © 1982 Thomas Nelson.', record.attribution
    end

    def test_changing_translation_replaces_stale_credit
      record = frame
      record.save!
      assert_equal 'NASB 1995 © The Lockman Foundation.', record.reload.attribution

      record.update!(translation: ' nkjv ')
      assert_equal 'NKJV', record.reload.translation
      assert_equal 'NKJV © 1982 Thomas Nelson.', record.attribution
    end

    def test_esv_is_available_automatically_and_replaces_previous_credit
      assert_includes Bible270::ScriptureFrames.translations, 'ESV'
      assert_equal 'ESV © 2001 Crossway.', Bible270::ScriptureFrames.attribution_for(' esv ')
      record = frame
      record.save!
      record.update!(translation: ' esv ', attribution: 'Forged credit.')

      assert_equal 'ESV', record.reload.translation
      assert_equal 'ESV © 2001 Crossway.', record.attribution
    end

    def test_additional_translations_save_with_automatic_credits_or_no_credit_for_kjv_and_ylt
      credits = {
        'LSB' => 'LSB © 2021 The Lockman Foundation.',
        'KJV' => nil,
        'CSB' => 'CSB © 2017 Holman Bible Publishers.',
        'NIV' => 'NIV © 1973, 1978, 1984, 2011 Biblica, Inc.',
        'YLT' => nil
      }
      record = frame
      record.save!

      credits.each do |code, credit|
        record.update!(translation: " #{code.downcase} ", attribution: 'Stale credit.')
        assert_equal code, record.reload.translation
        if credit
          assert_equal credit, record.attribution
          assert_equal credit, record[:attribution]
        else
          assert_nil record.attribution
          assert_nil record[:attribution]
        end
      end
    end

    def test_submitted_attribution_cannot_override_derived_credit
      record = frame(attribution: 'Forged credit.')
      record.save!
      assert_equal 'NASB 1995 © The Lockman Foundation.', record.reload.attribution

      record.update!(translation: 'NKJV', attribution: 'NASB 1995 © The Lockman Foundation.')
      assert_equal 'NKJV © 1982 Thomas Nelson.', record.reload.attribution
      record.update!(attribution: nil)
      assert_equal 'NKJV © 1982 Thomas Nelson.', record.reload.attribution
    end

    def test_host_translation_is_dynamic_and_bundled_translations_remain_valid
      bundled_codes = Bible270::ScriptureFrames.translations
      use_host_translation(code: ' host ', attribution: " Sample credit.\r\nSecond credit. ")
      record = frame(translation: ' host ')
      record.save!

      assert_equal 'HOST', record.reload.translation
      assert_equal "Sample credit.\nSecond credit.", record.attribution
      bundled_codes.each do |code|
        record = frame(translation: code)
        assert record.valid?, record.errors.full_messages.join(', ')
      end
    end

    def test_attribution_reads_current_registry_including_nil_with_stored_fallback_only_when_unregistered
      use_host_translation(attribution: 'Original credit.')
      record = frame(translation: 'HOST')
      record.save!

      use_host_translation(attribution: 'Revised credit.')
      assert_equal 'Revised credit.', record.attribution
      assert_equal 'Revised credit.', record.as_json.fetch('attribution')
      assert_equal 'Original credit.', record.reload[:attribution]
      assert_equal 'Revised credit.', record.attribution

      use_host_translation(attribution: nil)
      assert_nil record.attribution
      assert_nil record.as_json.fetch('attribution')
      assert_equal 'Original credit.', record[:attribution]

      Bible270.config.scripture_frames_path = nil
      assert_equal 'Original credit.', record.attribution
      assert_equal 'Original credit.', record.as_json.fetch('attribution')
    end

    def test_removed_translation_can_be_disabled_without_changing_saved_contents_or_credit
      use_host_translation(attribution: 'Original credit.')
      record = frame(translation: 'HOST')
      record.save!
      before = record.attributes.except('enabled', 'updated_at')
      Bible270.config.scripture_frames_path = nil

      assert record.update(enabled: false), record.errors.full_messages.join(', ')
      refute record.reload.enabled?
      assert_equal before, record.attributes.except('enabled', 'updated_at')
      assert_equal 'Original credit.', record.attribution
      refute record.valid?
      assert record.errors.of_kind?(:translation, :inclusion)
    end

    def test_disabling_exception_does_not_allow_creation_translation_changes_other_edits_or_enabling
      use_host_translation(attribution: 'Original credit.')
      record = frame(translation: 'HOST')
      record.save!
      Bible270.config.scripture_frames_path = nil

      created = frame(translation: 'HOST', enabled: false)
      refute created.save
      assert created.errors.of_kind?(:translation, :inclusion)

      before = record.attributes
      refute record.update(enabled: false, translation: 'OTHER')
      assert record.errors.of_kind?(:translation, :inclusion)
      assert_equal before, record.reload.attributes

      refute record.update(enabled: false, text: '')
      assert record.errors.of_kind?(:text, :blank)
      assert_equal before, record.reload.attributes

      refute record.update(enabled: false, reference: 'Edited reference')
      assert record.errors.of_kind?(:translation, :inclusion)
      assert_equal before, record.reload.attributes

      record.update!(enabled: false)
      before = record.reload.attributes
      refute record.update(enabled: true)
      assert record.errors.of_kind?(:translation, :inclusion)
      assert_equal before, record.reload.attributes
    end

    def test_public_domain_translation_keeps_nil_credit_and_clears_stale_credit
      use_host_translation(code: 'PUBLIC')
      record = frame
      record.save!
      record.update!(translation: ' public ', attribution: 'Forged credit.')

      assert_equal 'PUBLIC', record.reload.translation
      assert_nil record.attribution
      record.update!(attribution: 'Still forged.')
      assert_nil record.reload.attribution
    end

    def test_unsupported_translation_is_invalid_with_actionable_error_and_no_stale_credit
      record = frame(translation: 'unsupported', attribution: 'Wrong credit.')

      refute record.valid?
      assert_equal 'UNSUPPORTED', record.translation
      assert_includes record.errors[:translation], 'is unsupported; add translation and attribution to YAML'
      assert_nil record.attribution
      assert_raises(ActiveRecord::RecordInvalid) { record.save! }
    end

    def test_required_fields_cannot_be_blank
      %i[reference text translation].each do |attribute|
        [nil, '', " \r\n "].each do |value|
          record = frame(**{ attribute => value })
          refute record.valid?
          assert record.errors.of_kind?(attribute, :blank)
        end
      end
    end

    def test_reference_and_text_length_limits_allow_boundary_and_reject_overlong_fields
      { reference: 200, text: 4000 }.each do |attribute, maximum|
        record = frame(**{ attribute => 'x' * maximum })
        assert record.valid?, record.errors.full_messages.join(', ')
        record.public_send("#{attribute}=", 'x' * (maximum + 1))
        refute record.valid?
        assert record.errors.of_kind?(attribute, :too_long)
      end
    end

    def test_translation_length_limit_remains_independent_of_catalog_inclusion
      metadata = { ('X' * 40) => nil, ('X' * 41) => nil }
      Bible270::ScriptureFrames.stub(:translation_attributions, metadata) do
        record = frame(translation: 'x' * 40)
        assert record.valid?, record.errors.full_messages.join(', ')
        record.translation = 'x' * 41
        refute record.valid?
        assert record.errors.of_kind?(:translation, :too_long)
        refute record.errors.of_kind?(:translation, :inclusion)
      end
    end

    def test_attribution_length_limit_applies_to_derived_credit
      metadata = { 'NASB95' => 'a' * 500 }
      Bible270::ScriptureFrames.stub(:translation_attributions, metadata) do
        record = frame
        assert record.valid?, record.errors.full_messages.join(', ')
        assert_equal 'a' * 500, record.attribution
        metadata['NASB95'] = 'a' * 501
        refute record.valid?
        assert record.errors.of_kind?(:attribution, :too_long)
      end
    end

    def test_enabled_must_be_boolean_but_false_is_valid
      record = frame(enabled: false)
      assert record.valid?
      record.save!
      refute_includes Bible270::ScriptureFrame.enabled, record

      record.enabled = nil
      refute record.valid?
      assert record.errors.of_kind?(:enabled, :inclusion)
    end

    def test_database_defaults_constraints_and_enabled_index
      columns = Bible270::ScriptureFrame.columns_hash
      %w[reference text translation enabled].each { |name| refute columns.fetch(name).null }
      assert_equal 'NASB95', columns.fetch('translation').default
      assert(Bible270::ScriptureFrame.connection.indexes(:bible270_scripture_frames).any? { |index| index.columns == ['enabled'] })
    end

    def test_frames_are_sitewide_and_survive_restarts_and_reverts
      record = frame
      record.save!
      original = record.reload.attributes
      run = Bible270::PlanRun.current
      fresh = Bible270::PlanRun.restart!(start_date: Date.new(2027, 1, 1), expected_run_id: run.id)

      assert_equal original, Bible270::ScriptureFrame.find(record.id).attributes
      Bible270::PlanRun.revert!(expected_run_id: fresh.id)
      assert_equal original, Bible270::ScriptureFrame.find(record.id).attributes
      refute_includes Bible270::ScriptureFrame.column_names, 'reader_id'
      refute_includes Bible270::ScriptureFrame.column_names, 'plan_run_id'
    end
  end
end
