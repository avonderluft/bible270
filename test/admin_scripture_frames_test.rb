# frozen_string_literal: true

require_relative 'support/admin_scripture_frames_test_case'

if RAILS_LOADED
  class AdminScriptureFramesTest < Bible270AdminScriptureFramesTestCase
    def test_ordinary_admin_can_use_every_crud_action
      assert_crud_available(@admin)
    end

    def test_site_admin_can_use_every_crud_action
      assert_crud_available(@site_admin)
    end

    def test_alumni_ordinary_admin_can_use_every_crud_action_without_reactivation
      @admin.archive!
      before = @admin.participation.attributes

      assert_crud_available(@admin)

      assert @admin.reload.alumni?
      assert_equal before, @admin.participation.reload.attributes
    end

    def test_alumni_site_admin_can_use_every_crud_action_without_reactivation
      @site_admin.archive!
      before = @site_admin.participation.attributes

      assert_crud_available(@site_admin)

      assert @site_admin.reload.alumni?
      assert_equal before, @site_admin.participation.reload.attributes
    end

    def test_other_quotation_can_be_created_edited_toggled_and_deleted_without_bible_credits
      sign_in_as(@admin)
      post frames_path, params: { scripture_frame: { reference: 'An author, A book', translation: 'OTHER',
                                                     text: 'A quotation.', attribution: 'Forged Bible credit.', enabled: '1' } }
      assert_library_redirect('first_name')
      quote = Bible270::ScriptureFrame.order(:id).last
      assert_equal 'OTHER', quote.translation
      assert_nil quote.attribution

      get "#{frame_path(quote)}/edit"
      assert_select 'label[for="scripture_frame_reference"]', text: 'Author / source'
      assert_select 'option[value="OTHER"][selected]', text: 'Other quotation'
      assert_select '#b270-scripture-frame-credit[hidden]', text: ''
      assert_select 'script[data-b270-scripture-form-ui]', count: 1

      patch frame_path(quote), params: { scripture_frame: { text: '' } }
      assert_response :unprocessable_entity
      assert_select 'label[for="scripture_frame_reference"]', text: 'Author / source'
      assert_select 'option[value="OTHER"][selected]'
      assert_equal 'A quotation.', quote.reload.text

      get admin_path
      assert_select "article[aria-label='Custom text: An author, A book'] summary", text: 'An author, A book · Other quotation · Custom'
      patch frame_path(quote), params: { scripture_frame: { enabled: '0' } }
      refute quote.reload.enabled?
      patch frame_path(quote), params: { scripture_frame: { enabled: '1' } }
      assert quote.reload.enabled?
      patch frame_path(quote), params: { scripture_frame: { translation: 'ESV', reference: 'John 1:1' } }
      assert_equal 'ESV © 2001 Crossway.', quote.reload.attribution
      delete frame_path(quote)
      refute Bible270::ScriptureFrame.exists?(quote.id)
    end

    def test_each_text_field_rejects_overlong_values_on_create_and_update
      sign_in_as(@admin)
      { reference: 200, text: 4000, translation: 40 }.each do |field, limit|
        attributes = valid_attributes.merge(field => 'x' * (limit + 1))
        before = @frame.reload.attributes

        assert_no_difference('Bible270::ScriptureFrame.count') do
          post frames_path, params: { scripture_frame: attributes }
        end
        assert_response :unprocessable_entity
        assert_select '[role="alert"] li', minimum: 1

        patch frame_path(@frame), params: { scripture_frame: attributes }
        assert_response :unprocessable_entity
        assert_equal before, @frame.reload.attributes
      end
    end

    def test_exact_text_length_limits_are_accepted_with_a_supported_translation
      sign_in_as(@admin)
      attributes = { reference: 'R' * 200, text: 'T' * 4000, translation: 'NASB95', enabled: '1' }

      assert_difference('Bible270::ScriptureFrame.count', 1) do
        post frames_path, params: { scripture_frame: attributes }
      end
      assert_library_redirect
      created = Bible270::ScriptureFrame.order(:id).last
      assert_equal attributes.except(:enabled).stringify_keys, created.attributes.slice('reference', 'text', 'translation')
      assert_equal Bible270::ScriptureFrames.attribution_for('NASB95'), created.attribution
    end

    def test_supported_translation_at_the_length_limit_is_accepted
      sign_in_as(@admin)
      code = 'V' * 40
      codes = Bible270::ScriptureFrames.translations + [code]
      original_attribution_for = Bible270::ScriptureFrames.method(:attribution_for)
      credit = ->(translation) { translation == code ? 'Catalog translation credit.' : original_attribution_for.call(translation) }

      Bible270::ScriptureFrames.stub(:translations, codes) do
        Bible270::ScriptureFrames.stub(:attribution_for, credit) do
          post frames_path, params: { scripture_frame: valid_attributes.merge(translation: code) }
          assert_library_redirect
          created = Bible270::ScriptureFrame.order(:id).last
          assert_equal code, created.translation
          assert_equal credit.call(code), created.attribution
        end
      end
    end

    def test_unsupported_translations_are_rejected_on_create_and_update
      sign_in_as(@admin)
      ['', 'UNLISTED', '<b>NASB95</b>'].each do |code|
        before = @frame.reload.attributes
        attributes = valid_attributes.merge(translation: code)

        assert_no_difference('Bible270::ScriptureFrame.count') do
          post frames_path, params: { scripture_frame: attributes }
        end
        assert_response :unprocessable_entity
        assert_select '[role="alert"] li', minimum: 1

        patch frame_path(@frame), params: { scripture_frame: attributes }
        assert_response :unprocessable_entity
        assert_equal before, @frame.reload.attributes
      end
    end

    def test_forged_credit_is_ignored_and_derived_from_the_translation_on_create_and_update
      sign_in_as(@admin)
      nasb_credit = Bible270::ScriptureFrames.attribution_for('NASB95')
      nkjv_credit = Bible270::ScriptureFrames.attribution_for('NKJV')
      assert nasb_credit.present?
      assert nkjv_credit.present?
      refute_equal nasb_credit, nkjv_credit
      forged_credit = "<img src=x onerror=alert(1)>#{'x' * 501}"

      post frames_path, params: { scripture_frame: valid_attributes.merge(attribution: forged_credit) }
      assert_library_redirect
      created = Bible270::ScriptureFrame.order(:id).last
      assert_equal nasb_credit, created.attribution

      patch frame_path(created), params: { scripture_frame: { translation: 'NKJV', attribution: forged_credit } }
      assert_library_redirect
      assert_equal 'NKJV', created.reload.translation
      assert_equal nkjv_credit, created.attribution

      patch frame_path(created), params: { scripture_frame: { attribution: '' } }
      assert_library_redirect
      assert_equal nkjv_credit, created.reload.attribution

      get "#{frame_path(created)}/edit"
      assert_response :success
      assert_select '#b270-scripture-frame-credit', text: "Attribution: #{nkjv_credit}"
      assert_select '[name="scripture_frame[attribution]"]', count: 0
    end

    def test_blank_or_omitted_text_is_required_even_for_existing_references
      sign_in_as(@admin)
      [nil, '', " \r\n ", :omitted].each do |text|
        attributes = valid_attributes.except(:text)
        attributes[:text] = text unless text == :omitted

        assert_no_difference('Bible270::ScriptureFrame.count') do
          post frames_path, params: { scripture_frame: attributes }
        end
        assert_response :unprocessable_entity
        assert_select '[role="alert"] li', text: "Text can't be blank"
        assert_select 'input[name="scripture_frame[reference]"][value="Psalm 119:130"]'
        assert_select 'select[name="scripture_frame[translation]"] option[selected][value="NASB95"]'
        assert_select 'textarea[name="scripture_frame[text]"][required]'
      end
    end

    def test_blank_text_update_is_rejected_and_preserves_saved_data
      sign_in_as(@admin)
      before = @frame.attributes
      [nil, '', " \r\n "].each do |text|
        patch frame_path(@frame), params: { scripture_frame: { text: text } }

        assert_response :unprocessable_entity
        assert_select '[role="alert"] li', text: "Text can't be blank"
        assert_select 'textarea[name="scripture_frame[text]"][required]'
        assert_equal before, @frame.reload.attributes
      end
    end

    def test_partial_update_preserves_existing_text_when_omitted
      sign_in_as(@admin)
      patch frame_path(@frame), params: { scripture_frame: { reference: 'New reference' } }

      assert_library_redirect
      assert_equal 'New reference', @frame.reload.reference
      assert_equal valid_attributes[:text], @frame.text
    end

    def test_duplicate_custom_texts_are_allowed
      sign_in_as(@admin)

      assert_difference('Bible270::ScriptureFrame.count', 1) do
        post frames_path, params: { scripture_frame: valid_attributes }
      end

      assert_library_redirect
      assert_equal 2, Bible270::ScriptureFrame.where(reference: @frame.reference, text: @frame.text).count
    end

    def test_disabled_custom_text_can_be_enabled_and_disabled_without_losing_its_contents
      sign_in_as(@admin)
      before = @frame.attributes.except('enabled', 'updated_at')

      %w[0 1 0].each do |value|
        patch frame_path(@frame), params: { scripture_frame: { enabled: value } }

        assert_library_redirect
        assert_equal value == '1', @frame.reload.enabled?
        assert_equal before, @frame.attributes.except('enabled', 'updated_at')
      end
      visit_legacy_library
      assert_select 'article[aria-label="Custom text: Psalm 119:130"] summary', text: %r{ · Disabled\z}
    end

    def test_removed_translation_can_be_disabled_with_saved_credit_but_not_reenabled
      use_host_translation(attribution: 'Original credit.')
      @frame.update!(translation: 'HOST')
      before = @frame.attributes.except('enabled', 'updated_at')
      File.write(Bible270.config.scripture_frames_path, "[]\n")
      sign_in_as(@admin)

      visit_legacy_library
      assert_select 'article[aria-label="Custom text: Psalm 119:130"] summary', text: 'Psalm 119:130 · HOST · Custom'
      assert_equal 'Original credit.', @frame.reload.attribution

      patch frame_path(@frame), params: { scripture_frame: { enabled: '0' } }
      assert_library_redirect
      refute @frame.reload.enabled?
      assert_equal before, @frame.attributes.except('enabled', 'updated_at')

      visit_legacy_library
      assert_select 'article[aria-label="Custom text: Psalm 119:130"]' do
        assert_select 'summary', text: 'Psalm 119:130 · HOST · Custom · Disabled'
        assert_select '[data-b270-scripture-attribution]', count: 0
      end
      assert_equal 'Original credit.', @frame.reload.attribution

      before = @frame.reload.attributes
      patch frame_path(@frame), params: { scripture_frame: { enabled: '1' } }
      assert_response :unprocessable_entity
      assert_select '[role="alert"]', text: %r{unsupported}
      assert_equal before, @frame.reload.attributes
    end

    def test_disabling_does_not_allow_unsupported_creation_or_translation_changes
      sign_in_as(@admin)
      attributes = valid_attributes.merge(translation: 'UNLISTED', enabled: '0')
      before = @frame.attributes

      assert_no_difference('Bible270::ScriptureFrame.count') do
        post frames_path, params: { scripture_frame: attributes }
      end
      assert_response :unprocessable_entity
      assert_select '[role="alert"]', text: %r{unsupported}

      patch frame_path(@frame), params: { scripture_frame: attributes }
      assert_response :unprocessable_entity
      assert_select '[role="alert"]', text: %r{unsupported}
      assert_equal before, @frame.reload.attributes
    end

    def test_admin_previews_and_updates_use_corrected_yaml_credit_without_resaving_first
      use_host_translation(attribution: 'Original credit.')
      @frame.update!(translation: 'HOST')
      use_host_translation(attribution: 'Revised credit.')
      sign_in_as(@admin)

      visit_legacy_library
      assert_select 'article[aria-label="Custom text: Psalm 119:130"] [data-b270-scripture-attribution]', count: 0
      assert_equal 'Revised credit.', @frame.attribution

      get "#{mount}/admin"
      assert_response :success
      assert_select '#b270-scripture-frames article[data-source="custom"] p.b270-hint', count: 0

      get "#{frame_path(@frame)}/edit"
      assert_response :success
      assert_select '#b270-scripture-frame-credit', text: 'Attribution: Revised credit.'
      assert_equal 'Original credit.', @frame.reload[:attribution]
      assert_equal 'Revised credit.', @frame.attribution

      patch frame_path(@frame), params: { scripture_frame: { reference: 'Updated reference' } }
      assert_library_redirect
      assert_equal 'Revised credit.', @frame.reload[:attribution]
      assert_equal 'Revised credit.', @frame.attribution

      use_host_translation(attribution: nil)
      visit_legacy_library
      assert_select 'article[aria-label="Custom text: Updated reference"] [data-b270-scripture-attribution]', count: 0
      get "#{mount}/admin"
      assert_response :success
      assert_select '#b270-scripture-frames article[data-source="custom"] p.b270-hint', count: 0
      get "#{frame_path(@frame)}/edit"
      assert_response :success
      assert_select '#b270-scripture-frame-credit', text: 'Attribution: No attribution is configured for this translation.'
      assert_equal 'Revised credit.', @frame.reload[:attribution]
      assert_nil @frame.attribution
    end

    def test_create_and_update_only_accept_the_four_permitted_fields
      sign_in_as(@admin)
      forged = { id: 999_999, created_at: '1900-01-01', updated_at: '1900-01-01', plan_run_id: 999_999,
                 admin: true, attribution: 'Forged credit' }
      before = @frame.attributes

      post frames_path, params: { scripture_frame: valid_attributes.merge(forged) }

      assert_library_redirect
      created = Bible270::ScriptureFrame.order(:id).last
      refute_equal 999_999, created.id
      assert_operator created.created_at.year, :>, 1900
      assert_operator created.updated_at.year, :>, 1900
      assert_equal Bible270::ScriptureFrames.attribution_for('NASB95'), created.attribution
      assert_equal before, @frame.reload.attributes

      patch frame_path(created), params: { scripture_frame: forged.merge(reference: 'Psalm 1:1') }

      assert_library_redirect
      assert_equal 'Psalm 1:1', created.reload.reference
      assert_operator created.created_at.year, :>, 1900
      assert_operator created.updated_at.year, :>, 1900
      assert_equal Bible270::ScriptureFrames.attribution_for('NASB95'), created.attribution
      assert_equal before, @frame.reload.attributes
    end

    def test_pending_migration_blocks_forms_and_forged_mutations_gracefully
      sign_in_as(@admin)
      before = @frame.attributes
      Bible270::ScriptureFrames.stub(:custom_available?, false) do
        assert_no_difference('Bible270::ScriptureFrame.count') do
          [{}, { sort: 'consistency', return_to: 'texts' }, { sort: ['last_name'], return_to: '//evil.example/path' }].each do |context|
            requests.drop(1).each do |method, path, params|
              public_send(method, path, params: params.merge(context))

              assert_library_redirect(normalized_sort(context[:sort]))
              assert_match(%r{database migrations}, flash[:alert])
            end
          end
        end
      end
      assert_equal before, @frame.reload.attributes
    end
  end
end
