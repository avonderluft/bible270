# frozen_string_literal: true

require_relative 'support/admin_scripture_frames_test_case'

if RAILS_LOADED
  class AdminScriptureFrameCatalogTest < Bible270AdminScriptureFramesTestCase
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
  end
end
