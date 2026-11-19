# frozen_string_literal: true

require 'test_helper'
require 'bible270/scripture_frames'

if RAILS_LOADED
  class BundledScriptureCatalogTest < Minitest::Test
    CATALOG = Bible270::ScriptureFrames
    FIELD_LIMITS = { 'reference' => 200, 'translation' => 40, 'text' => 4000, 'attribution' => 500 }.freeze

    def setup
      @previous_path = Bible270.config.scripture_frames_path
      Bible270.config.scripture_frames_path = nil
      path = File.expand_path('../config/scripture_frames.yml', __dir__)
      @rows = YAML.safe_load(File.read(path, encoding: 'UTF-8'), permitted_classes: [], permitted_symbols: [], aliases: false)
      @frames = CATALOG.defaults
    end

    def teardown
      Bible270.config.scripture_frames_path = @previous_path
    end

    def test_bundled_yaml_has_a_nonempty_valid_schema_and_unique_stable_ids
      assert_kind_of Array, @rows
      refute_empty @rows
      @rows.each do |row|
        assert_kind_of Hash, row
        assert_empty row.keys - ['id', *FIELD_LIMITS.keys]
        assert_empty %w[id reference translation text] - row.keys
        assert_kind_of String, row['id']
        assert_match(%r{\A[a-z0-9]+(?:-[a-z0-9]+)*\z}, row['id'])
        FIELD_LIMITS.each do |field, limit|
          value = row[field]
          next if field == 'attribution' && value.nil?

          assert_kind_of String, value, "#{row['id']}: #{field} must be plaintext"
          normalized = value.gsub("\r\n", "\n").strip
          refute_empty normalized, "#{row['id']}: #{field} must not be blank" unless field == 'attribution'
          assert_operator normalized.length, :<=, limit, "#{row['id']}: #{field} is too long"
        end
      end
      ids = @rows.map { |row| row.fetch('id') }
      assert_equal ids.uniq, ids
    end

    def test_nil_configuration_parses_the_actual_bundled_rows_through_production
      assert_nil Bible270.config.scripture_frames_path
      expected = @rows.map do |row|
        fields = FIELD_LIMITS.keys.to_h do |field|
          value = row[field]&.gsub("\r\n", "\n")&.strip
          value = value.upcase if field == 'translation'
          value = nil if field == 'attribution' && value == ''
          [field.to_sym, value]
        end
        { id: "default:#{row.fetch('id')}", **fields }
      end
      assert_equal expected, @frames.map(&:to_h)
      assert_equal @frames.map(&:id), CATALOG.defaults.map(&:id)
    end

    def test_bundled_references_are_recognized_and_in_biblical_order
      positions = @frames.map do |frame|
        refute CATALOG.quotation?(frame.translation), "#{frame.id} must be a Bible passage"
        position = Bible270::Translations.reference_start(frame.reference)
        refute_nil position, "#{frame.id}: unrecognized Bible reference #{frame.reference.inspect}"
        position
      end
      assert_equal positions.sort, positions
      assert_equal @frames.map(&:id), CATALOG.in_biblical_order(@frames).map(&:id)
    end

    def test_translation_credits_are_consistent_and_public_domain_credits_may_be_nil
      metadata = CATALOG.translation_attributions
      @frames.group_by(&:translation).each do |code, frames|
        assert_equal code.strip.upcase, code
        assert metadata.key?(code), "Missing translation metadata for #{code}"
        assert_equal 1, frames.map(&:attribution).uniq.length, "Conflicting credits for #{code}"
        frames.each do |frame|
          assert_equal [metadata.fetch(code)], [frame.attribution], "Incorrect credit for #{frame.id}"
          assert_equal [frame.attribution], [CATALOG.attribution_for(code.downcase)]
        end
      end
    end
  end
end
