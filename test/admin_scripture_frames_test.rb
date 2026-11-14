# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class AdminScriptureFramesTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      Bible270::ScriptureFrame.delete_all
      @previous_config = %i[
        admin_emails admin_resolver current_reader_resolver registration_notice_deliver_later scripture_frames_path
      ].to_h { |key| [key, Bible270.config.public_send(key)] }
      Bible270.config.admin_resolver = nil
      Bible270.config.current_reader_resolver = nil
      Bible270.config.registration_notice_deliver_later = false
      Bible270.config.scripture_frames_path = nil

      @site_admin = create_reader('site-admin')
      @admin = create_reader('admin', admin: true)
      @reader = create_reader('reader')
      Bible270.config.admin_emails = [@site_admin.email]
      @frame = Bible270::ScriptureFrame.create!(valid_attributes)
      @directory = Dir.mktmpdir('admin-scripture-frames')
    end

    def teardown
      @previous_config&.each { |key, value| Bible270.config.public_send("#{key}=", value) }
      FileUtils.rm_rf(@directory) if @directory
    end

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

    def test_visitors_cannot_access_any_action
      assert_all_requests_hidden
    end

    def test_readers_cannot_access_any_action
      sign_in_as(@reader)
      assert_all_requests_hidden
    end

    def test_alumni_readers_cannot_access_any_action
      @reader.archive!
      sign_in_as(@reader)
      assert_all_requests_hidden
    end

    def test_ordinary_admin_reader_preview_cannot_access_any_action
      assert_preview_requests_hidden(@admin)
    end

    def test_site_admin_reader_preview_cannot_access_any_action
      assert_preview_requests_hidden(@site_admin)
    end

    def test_index_lists_enabled_and_disabled_custom_texts_with_native_delete_confirmation
      @frame.update!(enabled: false)
      enabled = Bible270::ScriptureFrame.create!(valid_attributes.merge(reference: 'Psalm 1:1'))
      sign_in_as(@admin)

      visit_legacy_library

      assert_select 'article[aria-label="Custom text: Psalm 119:130"]' do
        assert_select 'summary', text: %r{ · Disabled\z}
        assert_select '.b270-scripture-actions' do
          assert_select "> a[href='#{frame_path(@frame)}/edit?sort=first_name']", text: 'Edit'
          assert_select '> form', count: 2
          assert_select 'button', text: 'Enable'
          assert_select "form[action='#{frame_path(@frame)}'][data-b270-admin-confirm]" do
            assert_select 'input[name="_method"][value="delete"]'
            assert_select 'button', text: 'Delete'
          end
        end
      end
      assert_select 'article[aria-label="Custom text: Psalm 1:1"]' do
        assert_select 'summary', text: %r{ · Custom\z}
        assert_select '.b270-scripture-actions' do
          assert_select "> a[href='#{frame_path(enabled)}/edit?sort=first_name']", text: 'Edit'
          assert_select '> form', count: 2
          assert_select 'button', text: 'Disable'
          assert_select 'button', text: 'Delete'
        end
      end
      assert_select 'script[data-b270-admin-confirmations]'
      assert_select 'article[aria-label^="Custom text:"] > details:not([open])', count: 2
      assert_select 'article[aria-label^="Custom text:"] blockquote', count: 2
      assert_select 'article[aria-label="Custom text: Psalm 119:130"] blockquote', count: 1 do |nodes|
        assert_equal @frame.text, nodes.first.text
      end
      assert_select 'article[aria-label="Custom text: Psalm 1:1"] blockquote', count: 1 do |nodes|
        assert_equal enabled.text, nodes.first.text
      end
    end

    def test_bundled_texts_have_toggle_only_controls_and_do_not_become_database_records
      sign_in_as(@admin)
      defaults = default_attributes
      assert_equal %w[ESV NASB95 NKJV], defaults.map { |frame| frame[:translation] }.uniq.sort
      before = Bible270::ScriptureFrame.count

      visit_legacy_library

      assert_select '#b270-scripture-frames p', text: 'Custom texts supplement the bundled defaults', count: 0
      Bible270::ScriptureFrames.defaults.each do |frame|
        assert_select 'article[aria-label=?]', "Bundled text: #{frame.reference}" do
          assert_select 'summary', text: "#{frame.reference} · #{frame.translation} · Default"
          assert_select 'details:not([open])', count: 1
          assert_select 'blockquote', count: 1 do |nodes|
            assert_equal frame.text, nodes.first.text
          end
          assert_select '[data-b270-scripture-attribution]', count: 0
          assert_select 'form.b270-scripture-default-toggle', count: 1 do
            assert_select 'input[name="_method"][value="patch"]'
            assert_select 'input[type="hidden"][name="enabled"][value="0"]'
            assert_select 'button', text: 'Disable'
          end
          assert_select 'a', text: 'Edit', count: 0
          assert_select 'button', text: 'Delete', count: 0
        end
      end
      assert_equal defaults, default_attributes
      assert_equal before, Bible270::ScriptureFrame.count
    end

    def test_legacy_index_redirects_both_admin_roles_directly_to_the_panel_with_a_sanitized_sort
      [@admin, @site_admin].each do |admin|
        sign_in_as(admin)
        return_contexts.each do |params|
          get frames_path, params: params

          assert_library_redirect(normalized_sort(params[:sort]))
          follow_redirect!
          assert_response :success
          assert_select '#b270-scripture-frames', count: 1
          assert_select '#b270-custom-scripture-texts article[data-source="custom"]', count: 1
        end
      end
    end

    def test_new_and_edit_forms_keep_resource_actions_and_cancel_directly_to_the_panel_with_sanitized_sort
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

    def test_successful_create_update_and_delete_ignore_return_targets_and_preserve_only_allowlisted_sorts
      sign_in_as(@admin)
      return_contexts.each do |params|
        sort = normalized_sort(params[:sort])
        assert_difference('Bible270::ScriptureFrame.count', 1) do
          post frames_path, params: params.merge(scripture_frame: valid_attributes)
        end
        assert_library_redirect(sort)
        created = Bible270::ScriptureFrame.order(:id).last
        assert_equal valid_attributes[:text], created.text

        patch frame_path(created), params: params.merge(scripture_frame: { reference: 'Updated custom reference', enabled: '0' })
        assert_library_redirect(sort)
        assert_equal 'Updated custom reference', created.reload.reference
        refute created.enabled?

        assert_difference('Bible270::ScriptureFrame.count', -1) do
          delete frame_path(created), params: params
        end
        assert_library_redirect(sort)
        assert Bible270::ScriptureFrame.exists?(@frame.id)
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

    def test_bundled_ids_and_malformed_database_ids_cannot_be_edited_or_deleted
      sign_in_as(@admin)
      defaults = default_attributes
      before = Bible270::ScriptureFrame.order(:id).map(&:attributes)
      ids = Bible270::ScriptureFrames.defaults.map(&:id) + ["#{@frame.id}-bundled", '0', '999999999']

      ids.each do |id|
        get "#{frames_path}/#{id}/edit"
        assert_response :not_found
        patch "#{frames_path}/#{id}", params: { scripture_frame: valid_attributes.merge(text: 'Forged') }
        assert_response :not_found
        delete "#{frames_path}/#{id}"
        assert_response :not_found
      end

      assert_equal defaults, default_attributes
      assert_equal before, Bible270::ScriptureFrame.order(:id).map(&:attributes)
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

    def test_unauthorized_blank_text_requests_are_rejected
      post frames_path, params: { scripture_frame: valid_attributes.merge(reference: 'New reference', text: '') }
      assert_response :not_found
      sign_in_as(@reader)
      post frames_path, params: { scripture_frame: valid_attributes.merge(reference: 'New reference', text: '') }
      assert_response :not_found
      sign_in_as(@admin)
      patch "#{mount}/admin/view", params: { view: 'reader' }
      post frames_path, params: { scripture_frame: valid_attributes.merge(reference: 'New reference', text: '') }
      assert_response :not_found
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

    def test_custom_content_is_saved_as_plain_text_and_escaped_in_forms_and_full_passages
      sign_in_as(@admin)
      attributes = {
        reference: '<script>reference()</script>', text: "<script>text()</script>\nSecond line **not Markdown**",
        translation: 'NASB95', enabled: '1'
      }

      post frames_path, params: { scripture_frame: attributes }
      assert_library_redirect
      created = Bible270::ScriptureFrame.order(:id).last
      attributes.except(:enabled).each { |field, value| assert_equal value, created.public_send(field) }

      visit_legacy_library
      assert_includes response.body, '&lt;script&gt;text()&lt;/script&gt;'
      assert_includes response.body, '&lt;script&gt;reference()&lt;/script&gt;'
      assert_select 'article[aria-label^="Custom text:"] > details:not([open])', count: 2
      assert_select 'script', text: 'text()', count: 0
      assert_select 'img[onerror]', count: 0

      get "#{frame_path(created)}/edit"
      assert_response :success
      assert_select 'textarea[name="scripture_frame[text]"]', text: attributes[:text]
      assert_select 'input[name="scripture_frame[reference]"]' do |inputs|
        assert_equal attributes[:reference], inputs.first['value']
      end
      assert_select 'img[onerror]', count: 0
    end

    def test_pending_migration_index_shows_bundled_texts_and_upgrade_hint_without_custom_controls
      sign_in_as(@admin)
      Bible270::ScriptureFrames.stub(:custom_available?, false) do
        Bible270::ScriptureFrame.stub(:order, ->(*) { flunk 'Must not query custom frames before migration' }) do
          visit_legacy_library
        end
      end

      assert_select '#b270-scripture-frames .b270-hint', text: 'Run the pending database migration to add custom texts.'
      assert_select 'article[aria-label^="Bundled text:"]', count: Bible270::ScriptureFrames.defaults.length
      assert_select "a[href^='#{frames_path}/new']", count: 0
      assert_select "form[action^='#{frames_path}']", count: 0
      assert_select '#b270-default-scripture-texts form.b270-scripture-default-toggle', count: Bible270::ScriptureFrames.defaults.length
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

    def test_pending_migration_does_not_expose_endpoints_to_readers
      sign_in_as(@reader)
      Bible270::ScriptureFrames.stub(:custom_available?, false) { assert_all_requests_hidden }
    end

    def test_admin_bottom_panel_shows_compact_full_passages_without_credits_and_with_inline_actions
      @frame.update!(reference: 'Custom passage', text: "First custom line\n<script>Plain text, not HTML</script>\nLast custom line")
      attributes = valid_attributes.merge(
        reference: 'Disabled passage', text: "First disabled line\nLast disabled line", translation: 'NKJV', enabled: false
      )
      disabled = Bible270::ScriptureFrame.create!(attributes)
      defaults = Bible270::ScriptureFrames.defaults

      [@admin, @site_admin].each do |admin|
        sign_in_as(admin)
        get "#{mount}/admin"

        assert_response :success
        assert_match(/\.b270-scripture-library-text\{[^}]*font-size:15px;line-height:1\.5\}/, response.body)
        assert_match(%r{details\.b270-alumni\{margin-bottom:24px\}}, response.body)
        assert_select '#b270-alumni + #b270-scripture-frames', count: 1
        assert_select '#b270-scripture-frames + p a', text: '← Back to the plan'
        assert_select '#b270-scripture-frames' do
          assert_select '> details#b270-scripture-frames-list[open] > summary' do
            assert_select '.b270-disclosure-show', text: 'Show Scripture frames'
            assert_select '.b270-disclosure-hide', text: 'Hide Scripture frames'
          end
          assert_select "a[href='#{frames_path}']", count: 0
          assert_select "a[href='#{frames_path}/new?sort=first_name']", text: 'Add text'
          assert_select 'article[data-source="custom"] > details + .b270-scripture-actions', count: 2
          assert_select 'article', count: defaults.length + 2
          assert_select 'details.b270-scripture-library-disclosure:not([open])', count: defaults.length + 2
          assert_select 'script', count: 0
          assert_library_entries(defaults, source: 'default')
          assert_library_entries([@frame, disabled], source: 'custom')
        end
      end
    end

    def test_admin_bottom_panel_is_absent_in_reader_preview
      [@admin, @site_admin].each do |admin|
        sign_in_as(admin)
        patch "#{mount}/admin/view", params: { view: 'reader' }
        assert_response :see_other

        get "#{mount}/admin"

        assert_response :success
        assert_select '#b270-scripture-frames', count: 0
        assert_select "a[href='#{frames_path}']", count: 0
        assert_select "a[href^='#{frames_path}/new']", count: 0
      end
    end

    def test_admin_bottom_panel_keeps_default_toggles_when_custom_migration_is_pending
      sign_in_as(@admin)
      defaults = Bible270::ScriptureFrames.defaults
      Bible270::ScriptureFrames.stub(:custom_available?, false) do
        Bible270::ScriptureFrame.stub(:order, ->(*) { flunk 'Must not query custom frames before migration' }) do
          get "#{mount}/admin"
        end
      end

      assert_response :success
      assert_select '#b270-scripture-frames' do
        assert_select '.b270-hint', text: 'Run the pending database migration to add custom texts.'
        assert_select "a[href='#{frames_path}']", count: 0
        assert_select "a[href^='#{frames_path}/new']", count: 0
        assert_select 'article', count: defaults.length
        assert_select 'article[data-source="custom"]', count: 0
        assert_select 'form.b270-scripture-default-toggle', count: defaults.length
        assert_select "form[action^='#{frames_path}']", count: 0
        assert_select 'details.b270-scripture-library-disclosure:not([open])', count: defaults.length
        assert_library_entries(defaults, source: 'default')
      end
    end

  private

    def assert_library_entries(frames, source:)
      assert_select 'article[data-source=?]', source, count: frames.length do |entries|
        entries.zip(frames).each do |entry, frame|
          enabled = source == 'custom' ? frame.enabled? : !Bible270::ScriptureFrames.disabled_default_ids.include?(frame.id)
          disabled = enabled ? '' : ' · Disabled'
          label = source == 'custom' ? 'Custom text' : 'Bundled text'
          assert_equal "#{label}: #{frame.reference}", entry['aria-label']
          assert_select entry, '> details.b270-scripture-library-disclosure:not([open])', count: 1
          assert_select entry, 'summary', text: "#{frame.reference} · #{frame.translation} · #{source.capitalize}#{disabled}"
          assert_select entry, 'strong', text: frame.reference
          assert_select entry, 'blockquote', count: 1 do |nodes|
            assert_equal frame.text, nodes.first.text
          end
          assert_select entry, 'p', count: 0
          assert_select entry, 'p.b270-hint', count: 0
        end
      end
    end

    def return_contexts
      sorts = Bible270::AdminController::READER_SORT_OPTIONS.keys +
              [nil, '', 'https://evil.example/sort', 'first_name#bad', ['consistency'], { value: 'last_name' }]
      targets = [nil, '', 'admin', 'texts', 'https://evil.example/path', '//evil.example/path', '/admin',
                 'admin#bad', ['admin'], { value: 'admin' }]
      [{}] + sorts.map { |sort| { sort: sort, return_to: 'https://evil.example/path' } } +
        targets.flat_map { |target| ['consistency', '//evil.example/sort'].map { |sort| { return_to: target, sort: sort } } }
    end

    def normalized_sort(sort)
      Bible270::AdminController::READER_SORT_OPTIONS.key?(sort) ? sort : 'first_name'
    end

    def assert_form_return_context(sort)
      assert_select 'form.b270-form' do
        assert_select 'input[type="hidden"][name="sort"]', count: 1 do |inputs|
          assert_equal sort, inputs.first['value']
        end
        assert_select "a[href='#{library_path(sort)}']", text: 'Cancel', count: 1
      end
      assert_select "a[href='#{frames_path}']", count: 0
    end

    def mount = Bible270.config.mount_at.chomp('/')
    def admin_path = "#{mount}/admin"
    def frames_path = "#{admin_path}/scripture-frames"
    def frame_path(frame) = "#{frames_path}/#{frame.id}"
    def library_path(sort = 'first_name') = "#{admin_path}?sort=#{sort}#b270-scripture-frames"

    def assert_library_redirect(sort = 'first_name')
      assert_response :see_other
      assert_redirected_to library_path(sort)
    end

    def visit_legacy_library
      get frames_path
      assert_library_redirect
      follow_redirect!
      assert_response :success
    end

    def use_host_translation(attribution:)
      path = File.join(@directory, 'frames.yml')
      File.write(path, YAML.dump([{ 'id' => 'host-example', 'reference' => 'Host example',
                                    'text' => 'Sample text.', 'translation' => 'HOST', 'attribution' => attribution }]))
      Bible270.config.scripture_frames_path = path
    end

    def valid_attributes
      { reference: 'Psalm 119:130', text: "The unfolding of Your words gives light;\nIt gives understanding to the simple.",
        translation: 'NASB95', enabled: '1' }
    end

    def create_reader(name, admin: false)
      email = "scripture-frame-#{name}@example.org"
      Bible270::Reader.create!(provider: 'email', uid: email, email: email, display_name: name, admin: admin)
    end

    def sign_in_as(reader)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"
      assert_response :redirect
    end

    def requests
      [
        [:get, frames_path, {}],
        [:get, "#{frames_path}/new", {}],
        [:post, frames_path, { scripture_frame: valid_attributes }],
        [:get, "#{frame_path(@frame)}/edit", {}],
        [:patch, frame_path(@frame), { scripture_frame: { text: 'Forged change', enabled: '0' } }],
        [:delete, frame_path(@frame), {}]
      ]
    end

    def assert_all_requests_hidden
      before = Bible270::ScriptureFrame.order(:id).map(&:attributes)
      requests.each do |method, path, params|
        public_send(method, path, params: params.merge(view: 'admin', admin: true, site_admin: true))
        assert_response :not_found
      end
      assert_equal before, Bible270::ScriptureFrame.order(:id).map(&:attributes)
    end

    def assert_preview_requests_hidden(reader)
      sign_in_as(reader)
      patch "#{mount}/admin/view", params: { view: 'reader' }
      assert_response :see_other
      assert_all_requests_hidden

      patch "#{mount}/admin/view", params: { view: 'admin' }
      assert_response :see_other
      visit_legacy_library
    end

    def assert_crud_available(reader)
      sign_in_as(reader)
      defaults = default_attributes
      visit_legacy_library
      get "#{frames_path}/new"
      assert_response :success

      assert_difference('Bible270::ScriptureFrame.count', 1) do
        post frames_path, params: { scripture_frame: valid_attributes.merge(reference: 'Psalm 1:1') }
      end
      assert_library_redirect
      created = Bible270::ScriptureFrame.order(:id).last
      assert_equal 'Psalm 1:1', created.reference
      assert_equal 'NASB95', created.translation
      assert_equal Bible270::ScriptureFrames.attribution_for('NASB95'), created.attribution

      visit_legacy_library
      assert_select 'article[aria-label^="Bundled text:"]', count: defaults.length
      assert_select 'article[aria-label^="Custom text:"]', count: 2

      get "#{frame_path(created)}/edit"
      assert_response :success
      patch frame_path(created), params: {
        scripture_frame: { reference: 'Psalm 1:2', text: "First line\nSecond line", translation: 'NKJV', enabled: '0' }
      }
      assert_library_redirect
      assert_equal 'Psalm 1:2', created.reload.reference
      assert_equal "First line\nSecond line", created.text
      assert_equal 'NKJV', created.translation
      assert_equal Bible270::ScriptureFrames.attribution_for('NKJV'), created.attribution
      refute created.enabled?

      assert_difference('Bible270::ScriptureFrame.count', -1) { delete frame_path(created) }
      assert_library_redirect
      assert Bible270::ScriptureFrame.exists?(@frame.id)
      assert_equal defaults, default_attributes
    end

    def default_attributes
      Bible270::ScriptureFrames.defaults.map do |frame|
        %i[id reference text translation attribution].to_h { |field| [field, frame.public_send(field)] }
      end
    end
  end
end
