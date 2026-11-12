# frozen_string_literal: true

require 'test_helper'
require 'bible270/scripture_frames'

if RAILS_LOADED
  class ScriptureFramesControllerTest < ActionDispatch::IntegrationTest
    def setup
      clear_engine_tables!
      Bible270::ScriptureFrame.delete_all
      @previous_path = Bible270.config.scripture_frames_path
      Bible270.config.scripture_frames_path = nil
      @default_frames = Bible270::ScriptureFrames.defaults.map(&:dup)
      @directory = Dir.mktmpdir('scripture-frame-requests')
    end

    def teardown
      Bible270.config.scripture_frames_path = @previous_path
      Bible270::ScriptureFrame.delete_all
      FileUtils.rm_rf(@directory)
    end

    def endpoint
      "#{Bible270.config.mount_at.chomp('/')}/scripture-frame"
    end

    def default_ids
      @default_frames.map(&:id)
    end

    def empty_defaults
      path = File.join(@directory, 'empty.yml')
      File.write(path, "[]\n")
      Bible270.config.scripture_frames_path = path
    end

    def test_anonymous_visitor_gets_only_the_public_json_fields_and_no_store
      get endpoint

      assert_response :success
      assert_equal 'application/json', response.media_type
      assert_equal 'no-store', response.headers['Cache-Control']
      assert_includes default_ids, response.parsed_body['id']
      expected = @default_frames.find { |frame| frame.id == response.parsed_body['id'] }
      assert_equal expected.to_h.transform_keys(&:to_s), response.parsed_body
      assert_equal 0, Bible270::Reader.count
    end

    def test_each_default_is_public_with_its_own_text_translation_and_credit
      @default_frames.each do |frame|
        Bible270::ScriptureFrames.stub(:defaults, [frame.dup]) do
          get endpoint

          assert_response :success
          assert_equal frame.to_h.transform_keys(&:to_s), response.parsed_body
          assert_equal 'no-store', response.headers['Cache-Control']
        end
      end
    end

    def test_custom_plaintext_is_json_escaped_not_interpreted_or_stripped
      empty_defaults
      record = Bible270::ScriptureFrame.create!(reference: '<b>Example</b>', translation: 'NKJV',
                                                text: "<script>alert('sample')</script>\nA & B.", attribution: 'Forged credit.')
      get endpoint, as: :json

      assert_response :success
      assert_equal "custom:#{record.id}", response.parsed_body['id']
      assert_equal record.text, response.parsed_body['text']
      assert_equal record.reference, response.parsed_body['reference']
      assert_equal 'NKJV © 1982 Thomas Nelson.', response.parsed_body['attribution']
      refute_includes response.body, '<script>'
      refute_includes response.body, 'Forged credit.'
      assert_equal %w[attribution id reference text translation], response.parsed_body.keys.sort
    end

    def test_other_quotations_are_public_without_bible_credit_and_can_be_disabled
      empty_defaults
      quote = Bible270::ScriptureFrame.create!(reference: '<b>An author</b>', translation: 'OTHER', text: 'A quotation.')
      quote.update_column(:attribution, 'Stale Bible credit.')
      get endpoint, as: :json

      assert_response :success
      assert_equal "custom:#{quote.id}", response.parsed_body['id']
      assert_equal quote.reference, response.parsed_body['reference']
      assert_equal 'OTHER', response.parsed_body['translation']
      assert_nil response.parsed_body['attribution']
      refute_includes response.body, '<b>'
      quote.update!(enabled: false)
      get endpoint, as: :json
      assert_response :no_content
    end

    def test_public_custom_credit_tracks_yaml_corrections_and_explicit_nil_without_resaving
      path = File.join(@directory, 'frames.yml')
      row = { 'id' => 'host-example', 'reference' => 'Host example', 'translation' => 'HOST',
              'text' => 'Sample text.', 'attribution' => 'Original credit.' }
      File.write(path, YAML.dump([row]))
      Bible270.config.scripture_frames_path = path
      record = Bible270::ScriptureFrame.create!(reference: 'Custom example', text: 'Saved text.', translation: 'HOST')

      ['Revised credit.', nil].each do |credit|
        File.write(path, YAML.dump([row.merge('attribution' => credit)]))
        get endpoint, params: { exclude: 'default:host-example' }

        assert_response :success
        assert_equal "custom:#{record.id}", response.parsed_body['id']
        if credit
          assert_equal credit, record.attribution
          assert_equal credit, response.parsed_body['attribution']
        else
          assert_nil record.attribution
          assert_nil response.parsed_body['attribution']
        end
        assert_equal 'Original credit.', record.reload[:attribution]
      end

      empty_defaults
      get endpoint
      assert_response :success
      assert_equal "custom:#{record.id}", response.parsed_body['id']
      assert_equal 'Original credit.', response.parsed_body['attribution']
      record.update!(enabled: false)
      get endpoint
      assert_response :no_content
    end

    def test_exclusion_avoids_the_previous_frame_without_exposing_disabled_entries
      record = Bible270::ScriptureFrame.create!(reference: 'Enabled example', text: 'Sample text.')
      Bible270::ScriptureFrame.create!(reference: 'Disabled example', text: 'Hidden sample.', enabled: false)
      ids = default_ids + ["custom:#{record.id}"]

      ids.each do |previous|
        get endpoint, params: { exclude: previous }
        assert_response :success
        assert_includes ids - [previous], response.parsed_body['id']
      end
      empty_defaults
      get endpoint
      assert_equal "custom:#{record.id}", response.parsed_body['id']
    end

    def test_array_and_hash_exclusion_parameters_are_ignored_safely
      [[], ['default:psalm-119-130'], { id: 'default:psalm-119-130' }].each do |exclude|
        get endpoint, params: { exclude: exclude }
        assert_response :success
        assert_includes default_ids, response.parsed_body['id']
      end
    end

    def test_empty_pool_returns_no_content_and_no_store
      empty_defaults
      Bible270::ScriptureFrame.create!(reference: 'Disabled example', text: 'Hidden sample.', enabled: false)
      get endpoint

      assert_response :no_content
      assert_empty response.body
      assert_equal 'no-store', response.headers['Cache-Control']
    end

    def test_sole_frame_can_be_returned_again
      empty_defaults
      record = Bible270::ScriptureFrame.create!(reference: 'Enabled example', text: 'Sample text.')
      get endpoint, params: { exclude: "custom:#{record.id}" }

      assert_response :success
      assert_equal "custom:#{record.id}", response.parsed_body['id']
    end

    def test_endpoint_rejects_non_json_formats
      get "#{endpoint}.html"

      assert_response :not_acceptable
      assert_equal 'no-store', response.headers['Cache-Control']
      refute_includes response.body, 'The unfolding'
    end

    def test_disabling_all_defaults_returns_no_content_and_reenabling_preserves_public_fields
      default_ids.each { |id| Bible270::ScriptureFrames.set_default_enabled!(id, enabled: false) }
      get endpoint
      assert_response :no_content
      assert_empty response.body
      assert_equal 'no-store', response.headers['Cache-Control']
      assert_equal 0, Bible270::ScriptureFrame.count

      frame = @default_frames.first
      Bible270::ScriptureFrames.set_default_enabled!(frame.id, enabled: true)
      get endpoint, params: { exclude: frame.id }
      assert_response :success
      assert_equal frame.to_h.transform_keys(&:to_s), response.parsed_body
      assert_equal %w[attribution id reference text translation], response.parsed_body.keys.sort
    end

    def test_disabled_defaults_do_not_hide_a_custom_frame_with_the_same_reference
      frame = @default_frames.first
      record = Bible270::ScriptureFrame.create!(reference: frame.reference, translation: frame.translation, text: 'Independent text.')
      default_ids.each { |id| Bible270::ScriptureFrames.set_default_enabled!(id, enabled: false) }
      get endpoint, params: { exclude: "custom:#{record.id}" }
      assert_response :success
      assert_equal "custom:#{record.id}", response.parsed_body['id']
      assert_equal 'Independent text.', response.parsed_body['text']
      assert record.reload.enabled?
    end

    def test_public_endpoint_works_before_the_settings_table_exists
      Bible270::Setting.stub(:table_exists?, false) do
        get endpoint
        assert_response :success
        assert_includes @default_frames.map { |frame| frame.to_h.transform_keys(&:to_s) }, response.parsed_body
      end
    end

    def test_public_endpoint_works_before_the_custom_table_exists
      Bible270::ScriptureFrame.stub(:table_exists?, false) do
        get endpoint
        assert_response :success
        assert_includes @default_frames.map { |frame| frame.to_h.transform_keys(&:to_s) }, response.parsed_body
      end
    end
  end
end
