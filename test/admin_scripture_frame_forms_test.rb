# frozen_string_literal: true

require_relative 'support/admin_scripture_frames_test_case'

if RAILS_LOADED
  class AdminScriptureFrameFormsTest < Bible270AdminScriptureFramesTestCase
    def test_new_and_edit_forms_keep_resource_actions_and_cancel_directly_to_the_panel_with_sanitized_sort
      # Other form tests exercise the full layout; keep this context matrix focused.
      Bible270.config.layout = false
      sign_in_as(@admin)
      return_contexts.each do |params|
        sort = normalized_sort(params[:sort])
        [["#{frames_path}/new", frames_path], ["#{frame_path(@frame)}/edit", frame_path(@frame)]].each do |path, action|
          get path, params: params

          assert_response :success
          assert_select "form.b270-form[action='#{action}'][method='post']", count: 1 do
            assert_select 'input[type="hidden"][name="sort"]', count: 1 do |inputs|
              assert_equal sort, inputs.first['value']
            end
            assert_select "a[href='#{library_path(sort)}']", text: 'Cancel', count: 1
            assert_select 'input[name="_method"][value="patch"]', count: action == frames_path ? 0 : 1
          end
          assert_select "a[href='#{frames_path}'], a[href^='#{frames_path}#']", count: 0
        end
      end
    end

    def test_validation_errors_keep_sanitized_sort_and_direct_cancel_links_on_new_and_edit_forms
      sign_in_as(@admin)
      ['consistency', 'https://evil.example/sort', ['last_name']].each do |sort|
        params = { sort: sort, return_to: 'https://evil.example/path', scripture_frame: valid_attributes.merge(text: '') }
        before = @frame.reload.attributes
        assert_no_difference('Bible270::ScriptureFrame.count') do
          post frames_path, params: params
        end
        assert_response :unprocessable_entity
        assert_form_return_context(normalized_sort(sort))

        patch frame_path(@frame), params: params
        assert_response :unprocessable_entity
        assert_form_return_context(normalized_sort(sort))
        assert_equal before, @frame.reload.attributes
      end
    end

    def test_new_form_defaults_and_accessible_bounded_plain_text_fields
      sign_in_as(@admin)

      get "#{frames_path}/new"

      assert_response :success
      assert_select 'form' do
        { reference: 200, text: 4000 }.each do |field, limit|
          assert_select "label[for='scripture_frame_#{field}']"
          assert_select "[name='scripture_frame[#{field}]'][maxlength='#{limit}'][required]"
        end
        assert_select '.b270-select-wrap select.b270-select[name="scripture_frame[translation]"][required]' do
          assert_select 'option[selected][value="NASB95"]'
          assert_select 'option:not([value=""])' do |options|
            assert_equal %w[NKJV NASB95 LSB ESV KJV YLT CSB NIV OTHER], options.map { |option| option['value'] }.to_a
          end
        end
        assert_select 'label[for="scripture_frame_translation"]'
        assert_select '[name="scripture_frame[attribution]"]', count: 0
        assert_select 'input[type="checkbox"][name="scripture_frame[enabled]"][checked]'
        assert_select 'label[for="scripture_frame_text"]', text: 'Text'
        assert_select 'textarea[name="scripture_frame[text]"][required]'
        assert_select '#b270-scripture-frame-lookup', count: 0
        assert_select '.b270-scripture-fields', count: 1 do
          assert_select '> .b270-field', count: 2
          assert_select 'label[for="scripture_frame_reference"] + input[name="scripture_frame[reference]"]'
          assert_select 'label[for="scripture_frame_translation"] + .b270-select-wrap select[name="scripture_frame[translation]"]'
        end
        assert_select '.b270-scripture-fields + .b270-field textarea[name="scripture_frame[text]"]'
      end
      assert_select '#b270-scripture-frame-rights', text: 'Bible translation credits are added automatically. For other quotations, name the author or source. Use text you have permission to reproduce.'
      assert_select '#b270-scripture-frame-credit', text: "Attribution: #{Bible270::ScriptureFrames.attribution_for('NASB95')}"
    end

    def test_translation_choices_follow_the_registry_on_new_and_edit_forms
      sign_in_as(@admin)
      codes = Bible270::ScriptureFrames.translations + ['CATALOG']
      @frame.update!(translation: 'NKJV')

      Bible270::ScriptureFrames.stub(:translations, codes) do
        ["#{frames_path}/new", "#{frame_path(@frame)}/edit"].each do |path|
          get path

          assert_response :success
          assert_select 'select[name="scripture_frame[translation]"]' do
            assert_select 'option[value=""]', count: 1
            assert_select 'option:not([value=""])' do |options|
              assert_equal codes + ['OTHER'], options.map { |option| option['value'] }.to_a
            end
          end
          selected = path.end_with?('/new') ? 'NASB95' : 'NKJV'
          assert_select "select[name='scripture_frame[translation]'] option[selected][value='#{selected}']"
          assert_select '#b270-scripture-frame-credit', text: "Attribution: #{Bible270::ScriptureFrames.attribution_for(selected)}"
          assert_select '[name="scripture_frame[attribution]"]', count: 0
        end
      end
    end

    def test_edit_keeps_an_unavailable_translation_unselected_instead_of_selecting_another_code
      sign_in_as(@admin)
      codes = Bible270::ScriptureFrames.translations - [@frame.translation]
      refute_empty codes

      Bible270::ScriptureFrames.stub(:translations, codes) do
        get "#{frame_path(@frame)}/edit"
      end

      assert_response :success
      assert_select 'select[name="scripture_frame[translation]"][required]' do
        assert_select 'option:first-child[value=""]', count: 1
        assert_select 'option[selected]:not([value=""])', count: 0
        assert_select 'option:not([value=""])' do |options|
          assert_equal codes + ['OTHER'], options.map { |option| option['value'] }.to_a
        end
      end
      assert_equal 'NASB95', @frame.reload.translation
    end

    def test_invalid_create_displays_errors_and_retains_submitted_values_with_422
      sign_in_as(@admin)
      attributes = valid_attributes.merge(reference: '', text: 'Keep these words')

      assert_no_difference('Bible270::ScriptureFrame.count') do
        post frames_path, params: { scripture_frame: attributes }
      end

      assert_response :unprocessable_entity
      assert_select '[role="alert"] li', minimum: 1
      assert_select 'textarea[name="scripture_frame[text]"]', text: 'Keep these words'
      assert_select 'select[name="scripture_frame[translation]"] option[selected][value="NASB95"]'
    end

    def test_invalid_update_displays_errors_and_leaves_database_unchanged
      sign_in_as(@admin)
      before = @frame.attributes

      patch frame_path(@frame), params: { scripture_frame: valid_attributes.merge(reference: 'Unlisted passage', text: '') }

      assert_response :unprocessable_entity
      assert_select '[role="alert"] li', minimum: 1
      assert_select "form[action='#{frame_path(@frame)}']"
      assert_select 'select[name="scripture_frame[translation]"] option[selected][value="NASB95"]'
      assert_equal before, @frame.reload.attributes
    end
  end
end
