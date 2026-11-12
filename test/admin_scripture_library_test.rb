# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class AdminScriptureLibraryTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_config = %i[
        admin_emails admin_resolver current_reader_resolver registration_notice_deliver_later scripture_frames_path
      ].to_h { |key| [key, Bible270.config.public_send(key)] }
      Bible270.config.admin_resolver = nil
      Bible270.config.current_reader_resolver = nil
      Bible270.config.registration_notice_deliver_later = false
      Bible270.config.scripture_frames_path = nil
      @admin = create_reader('admin', admin: true)
      @site_admin = create_reader('site-admin')
      Bible270.config.admin_emails = [@site_admin.email]
      @frame = Bible270::ScriptureFrame.create!(
        reference: 'Custom <passage>', translation: 'NASB95',
        text: "First line & more\n<script>Plain text, not HTML</script>\nLast line", enabled: true
      )
      @disabled = Bible270::ScriptureFrame.create!(
        reference: 'Disabled passage', translation: 'NKJV', text: 'Saved but disabled.', enabled: false
      )
      sign_in_as(@admin)
    end

    def teardown
      @previous_config&.each { |key, value| Bible270.config.public_send("#{key}=", value) }
    end

    def test_main_admin_has_native_disclosures_with_described_tooltips_and_inline_actions
      [@admin, @site_admin].each do |admin|
        sign_in_as(admin)
        get admin_path

        assert_response :success
        assert_select 'script[data-b270-scripture-library-ui]', count: 1
        assert_select '#b270-alumni + section#b270-scripture-frames', count: 1
        assert_select '#b270-scripture-frames + p a', text: '← Back to the plan'
        assert_select '#b270-scripture-frames' do
          assert_select "a[href='#{frames_path}']", count: 0
          assert_select "a[href='#{frames_path}/new?sort=first_name']", text: 'Add text'
          assert_select 'script, [title], .b270-scripture-art, .b270-scripture-art__attribution', count: 0
          assert_custom_actions(sort: 'first_name')
          assert_default_toggles(sort: 'first_name')
          assert_library_entries(Bible270::ScriptureFrames.defaults, source: 'default')
          assert_library_entries([@frame, @disabled], source: 'custom')
          sources = css_select('#b270-scripture-frames article').map { |entry| entry['data-source'] }
          assert_equal %w[custom custom] + (['default'] * Bible270::ScriptureFrames.defaults.length), sources
        end
        ids = css_select('#b270-scripture-frames [id]').map { |element| element['id'] }
        assert_equal ids.uniq, ids
      end
    end

    def test_passages_preserve_plain_text_line_breaks_without_html_or_attribution
      get admin_path

      assert_select '#b270-scripture-frames article[data-source="custom"]' do |entries|
        entry = entries.first
        assert_select entry, 'summary', text: 'Custom <passage> · NASB95 · Custom'
        assert_select entry, 'blockquote' do |texts|
          assert_equal @frame.text, texts.first.text
          assert_empty texts.first.element_children
          assert_includes texts.first.inner_html, '&lt;script&gt;Plain text, not HTML&lt;/script&gt;'
        end
        refute_includes entry.text, @frame.attribution
      end
    end

    def test_tooltip_styles_cover_hover_focus_scrolling_and_native_open_fallback
      @frame.update!(text: "First line\n#{'x' * 3980}")
      get admin_path

      assert_select '#b270-scripture-frames article[data-source="custom"] blockquote' do |texts|
        assert_equal @frame.text, texts.first.text
      end
      styles = css_select('style').map(&:text).join
      assert_includes styles, '.b270-scripture-library-disclosure::details-content{display:block;content-visibility:visible}'
      assert_includes styles, '.b270-scripture-library-disclosure:not([open])>.b270-scripture-library-text{display:none}'
      assert_includes styles, '.b270-scripture-library-disclosure:not([data-b270-scripture-preview-dismissed]):hover>.b270-scripture-library-text'
      assert_includes styles, '.b270-scripture-library-disclosure:not([data-b270-scripture-preview-dismissed]):focus-within>.b270-scripture-library-text{display:block}'
      assert_match(%r{\.b270-scripture-library-disclosure>\.b270-scripture-library-text\{[^\}]*width:min\(32rem,100%\);max-height:50vh;max-height:50dvh;overflow:auto}, styles)
      assert_match(%r{\.b270-scripture-library-text\{[^\}]*white-space:pre-wrap;overflow-wrap:anywhere}, styles)
      assert_includes styles, '.b270-scripture-library-text:focus-visible{outline:2px solid var(--gold);outline-offset:2px}'
      assert_includes styles, 'background:var(--paper);background:color-mix(in srgb,var(--card) 90%,var(--gold))'
      assert_includes styles, '.b270-scripture-library-disclosure[open]>.b270-scripture-library-text{position:relative;inset:auto;width:100%;margin-top:8px}'
      assert_includes styles, 'details.b270-alumni{margin-bottom:24px}'
    end

    def test_custom_actions_and_default_buttons_are_in_the_right_hand_column_with_single_line_actions
      get admin_path

      assert_response :success
      assert_select '#b270-custom-scripture-texts article > details + .b270-scripture-actions', count: 2
      assert_select '#b270-default-scripture-texts article > details + form.b270-scripture-default-toggle', count: Bible270::ScriptureFrames.defaults.length
      styles = css_select('style').map(&:text).join
      %w[custom default].each do |source|
        assert_match(%r{\.b270-scripture-library-entry--#{source}[^\{]*\{[^\}]*display:grid;grid-template-columns:minmax\(0,1fr\) auto;}, styles)
      end
      assert_match(%r{\.b270-scripture-actions\{[^\}]*display:flex;[^\}]*white-space:nowrap}, styles)
      assert_select '#b270-scripture-frames .b270-scripture-actions > br, #b270-scripture-frames details form', count: 0
    end

    def test_pending_migration_keeps_default_disclosures_without_custom_queries_or_add_link
      Bible270::ScriptureFrames.stub(:custom_available?, false) do
        Bible270::ScriptureFrame.stub(:order, ->(*) { flunk 'Must not query custom texts before migration' }) do
          get admin_path
        end
      end

      assert_response :success
      assert_select '#b270-scripture-frames' do
        assert_select '.b270-hint', text: 'Run the pending database migration to add custom texts.'
        assert_select "a[href='#{frames_path}']", count: 0
        assert_select "a[href^='#{frames_path}/new']", count: 0
        assert_select 'article[data-source="custom"]', count: 0
        assert_library_entries(Bible270::ScriptureFrames.defaults, source: 'default')
        assert_default_toggles(sort: 'first_name')
      end
    end

    def test_reader_preview_does_not_expose_the_library_or_new_active_reader_controls
      [@admin, @site_admin].each do |admin|
        sign_in_as(admin)
        patch "#{admin_path}/view", params: { view: 'reader' }
        assert_response :see_other
        get admin_path

        assert_response :success
        assert_select '#b270-scripture-frames, #b270-active-readers, #b270-reader-stats-dialog', count: 0
        assert_select "a[href='#{frames_path}'], a[href='#{frames_path}/new']", count: 0
        assert_select '.b270-scripture-library-text', count: 0
      end
    end

    def test_add_text_sits_beside_panel_heading_above_custom_first_list_without_group_labels
      get admin_path

      assert_response :success
      assert_select 'script[data-b270-scripture-library-ui]', count: 1 do |scripts|
        assert_empty scripts.first.ancestors('#b270-scripture-frames')
        assert scripts.first.xpath('preceding::*[@id="b270-scripture-frames"]').any?, 'Library script must follow the main panel'
      end
      assert_select '#b270-scripture-frames' do
        assert_select '#b270-scripture-frames-heading', text: 'Scripture frames'
        assert_select '#b270-scripture-frames-heading' do |headings|
          assert_select headings.first.parent, "> a[href='#{frames_path}/new?sort=first_name']", text: 'Add text', count: 1
        end
        assert_select 'h3, .b270-scripture-group-heading', count: 0
        assert_select "a[href='#{frames_path}/new?sort=first_name']", count: 1
        assert_select '#b270-custom-scripture-texts + #b270-default-scripture-texts', count: 1
        assert_select '#b270-custom-scripture-texts' do
          assert_select 'article.b270-scripture-library-entry--custom', count: 2
          assert_select 'article > details.b270-scripture-library-disclosure:not([open])', count: 2
          assert_custom_actions(sort: 'first_name')
          assert_select 'blockquote' do |passages|
            assert_equal [@frame.text, @disabled.text], passages.map(&:text).to_a
          end
        end
        assert_select '#b270-default-scripture-texts' do
          assert_select 'article > details.b270-scripture-library-disclosure:not([open])', count: Bible270::ScriptureFrames.defaults.size
          assert_select '.b270-scripture-actions', count: 0
          assert_default_toggles(sort: 'first_name')
        end
        assert_select '.b270-scripture-art, .b270-scripture-library-entry [data-b270-scripture-attribution]', count: 0
      end
      ids = css_select('.b270-scripture-library-text').map { |entry| entry['id'] }
      assert_equal ids.uniq, ids
    end

    def test_custom_scripture_is_sorted_biblically_before_quotations_and_defaults
      references = ['John 3:16', 'Psalm 119:103', 'Genesis 1:1', 'Psa 119.11', 'Deut. 6.6-7']
      references.each { |reference| Bible270::ScriptureFrame.create!(reference: reference, text: 'Passage.', translation: 'ESV') }
      Bible270::ScriptureFrame.create!(reference: 'An author', text: 'A quotation.', translation: 'OTHER')

      get admin_path
      actual = css_select('#b270-custom-scripture-texts summary strong').map(&:text)
      assert_equal ['Genesis 1:1', 'Deut. 6.6-7', 'Psa 119.11', 'Psalm 119:103', 'John 3:16',
                    @frame.reference, @disabled.reference, 'An author'], actual
      sources = css_select('#b270-scripture-frames article').map { |entry| entry['data-source'] }
      assert_equal (['custom'] * actual.length) + (['default'] * Bible270::ScriptureFrames.defaults.length), sources
    end

    def test_main_panel_has_no_redundant_description_instructional_hints_or_manage_links
      get admin_path

      assert_response :success
      assert_select 'a', text: 'Manage texts', count: 0
      assert_select "a[href='#{frames_path}'], a[href^='#{frames_path}?']", count: 0
      assert_select '#b270-scripture-frames' do |panels|
        assert_select 'p', text: 'Custom texts supplement the bundled defaults', count: 0
        assert_select '[title]', count: 0
        refute_match(%r{hover|focus|All defaults start enabled|Admin additions supplement|YAML defaults}i, panels.first.text)
      end
    end

    def test_disabled_defaults_stay_previewable_with_enable_buttons_after_legacy_redirect
      frame = Bible270::ScriptureFrames.defaults.first
      Bible270::ScriptureFrames.set_default_enabled!(frame.id, enabled: false)

      [admin_path, frames_path].each do |path|
        get path, params: { sort: 'consistency' }
        if path == frames_path
          assert_response :see_other
          assert_redirected_to "#{admin_path}?sort=consistency#b270-scripture-frames"
          follow_redirect!
        end

        assert_response :success
        assert_select '#b270-scripture-frames' do
          assert_default_toggles(sort: 'consistency')
          assert_select '.b270-scripture-library-entry--default summary',
                        text: "#{frame.reference} · #{frame.translation} · Default · Disabled", count: 1
          assert_select '.b270-scripture-library-entry--default blockquote', count: Bible270::ScriptureFrames.defaults.length
        end
      end
    end

    def test_all_main_panel_actions_preserve_each_allowlisted_sort_and_normalize_untrusted_sorts
      (Bible270::AdminController::READER_SORT_OPTIONS.keys + ['https://evil.example/sort', ['consistency'], { value: 'last_name' }]).each do |sort|
        get admin_path, params: { sort: sort }

        assert_response :success
        expected = Bible270::AdminController::READER_SORT_OPTIONS.key?(sort) ? sort : 'first_name'
        assert_select '#b270-scripture-frames' do
          assert_select "a[href='#{frames_path}/new?sort=#{expected}']", text: 'Add text'
          assert_custom_actions(sort: expected)
          assert_default_toggles(sort: expected)
        end
      end
    end

    def test_unavailable_default_settings_hide_only_default_buttons_not_passage_previews_or_custom_controls
      Bible270::ScriptureFrames.stub(:default_settings_available?, false) do
        get admin_path
        assert_response :success
        assert_select '#b270-scripture-frames' do
          assert_library_entries(Bible270::ScriptureFrames.defaults, source: 'default')
          assert_select 'form.b270-scripture-default-toggle', count: 0
          assert_select "a[href='#{frames_path}/new?sort=first_name']", text: 'Add text'
          assert_custom_actions(sort: 'first_name')
        end

        get frames_path
        assert_response :see_other
        assert_redirected_to "#{admin_path}?sort=first_name#b270-scripture-frames"
        follow_redirect!
        assert_response :success
        assert_select '#b270-default-scripture-texts' do
          assert_select 'details.b270-scripture-library-disclosure:not([open])', count: Bible270::ScriptureFrames.defaults.length
          assert_select 'blockquote', count: Bible270::ScriptureFrames.defaults.length
          assert_select 'form, button', count: 0
        end
        assert_select '#b270-custom-scripture-texts .b270-scripture-actions', count: 2
        assert_select '#b270-custom-scripture-texts button', text: 'Delete', count: 2
      end
    end

  private

    def assert_custom_actions(sort:)
      assert_select 'article.b270-scripture-library-entry--custom[data-source="custom"]', count: 2 do |entries|
        entries.zip([@frame, @disabled]).each do |entry, frame|
          path = "#{frames_path}/#{frame.id}"
          assert_select entry, '> details.b270-scripture-library-disclosure + .b270-scripture-actions', count: 1 do
            assert_select "> a[href='#{path}/edit?sort=#{sort}']", text: 'Edit', count: 1 do |links|
              assert_equal "Edit #{frame.reference}", links.first['aria-label']
            end
            assert_select "> form[action='#{path}'][method='post']", count: 2 do |forms|
              forms.each do |form|
                assert_select form, 'input[type="hidden"][name="sort"]', count: 1 do |inputs|
                  assert_equal sort, inputs.first['value']
                end
              end
            end
            assert_select 'form:has(input[name="_method"][value="patch"])', count: 1 do
              assert_select 'input[type="hidden"][name="scripture_frame[enabled]"]', count: 1 do |inputs|
                assert_equal frame.enabled? ? '0' : '1', inputs.first['value']
              end
              action = frame.enabled? ? 'Disable' : 'Enable'
              assert_select 'button[type="submit"]', text: action, count: 1 do |buttons|
                assert_equal "#{action} #{frame.reference}", buttons.first['aria-label']
              end
            end
            assert_select 'form[data-b270-admin-confirm]', count: 1 do |forms|
              assert_match(%r{delete}i, forms.first['data-b270-admin-confirm'])
              assert_select 'input[name="_method"][value="delete"]', count: 1
              assert_select 'button[type="submit"]', text: 'Delete', count: 1 do |buttons|
                assert_equal "Delete #{frame.reference}", buttons.first['aria-label']
              end
            end
          end
          assert_select entry, 'details a, details form, summary button, br', count: 0
        end
      end
    end

    def assert_default_toggles(sort:)
      defaults = Bible270::ScriptureFrames.defaults
      disabled_ids = Bible270::ScriptureFrames.disabled_default_ids
      assert_select 'article.b270-scripture-library-entry--default[data-source="default"]', count: defaults.length do |entries|
        entries.zip(defaults).each do |entry, frame|
          enabled = !disabled_ids.include?(frame.id)
          action = enabled ? 'Disable' : 'Enable'
          assert_select entry, '> details.b270-scripture-library-disclosure + form.b270-scripture-default-toggle[method="post"]', count: 1 do |forms|
            assert_equal "#{admin_path}/scripture-frame-defaults/#{frame.id}", forms.first['action']
            assert_select 'input[type="hidden"][name="_method"][value="patch"]', count: 1
            assert_select 'input[type="hidden"][name="enabled"]', count: 1 do |inputs|
              assert_equal enabled ? '0' : '1', inputs.first['value']
            end
            assert_select 'input[type="hidden"][name="sort"]', count: 1 do |inputs|
              assert_equal sort, inputs.first['value']
            end
            assert_select 'button[type="submit"]', text: action, count: 1 do |buttons|
              assert_equal "#{action} #{frame.reference}", buttons.first['aria-label']
            end
          end
          assert_select entry, 'form', count: 1
          assert_select entry, 'details form, summary button, .b270-scripture-actions, a', count: 0
          assert_select entry, 'details > blockquote[role="tooltip"][tabindex="0"]', count: 1 do |texts|
            assert_equal frame.text, texts.first.text
          end
          disabled = enabled ? '' : ' · Disabled'
          assert_select entry, 'summary', text: "#{frame.reference} · #{frame.translation} · Default#{disabled}"
        end
      end
    end

    def assert_library_entries(frames, source:)
      assert_select 'article.b270-scripture-library-entry[data-source=?]', source, count: frames.length do |entries|
        entries.zip(frames).each do |entry, frame|
          label = source == 'custom' ? 'Custom text' : 'Bundled text'
          assert_equal "#{label}: #{frame.reference}", entry['aria-label']
          enabled = source == 'custom' ? frame.enabled? : !Bible270::ScriptureFrames.disabled_default_ids.include?(frame.id)
          disabled = enabled ? '' : ' · Disabled'
          assert_select entry, '> details.b270-scripture-library-disclosure:not([open])', count: 1 do
            assert_select '> summary', text: "#{frame.reference} · #{frame.translation} · #{source.capitalize}#{disabled}" do |summaries|
              assert_select 'strong', text: frame.reference
              assert_select 'blockquote, .b270-scripture-library-text', count: 0
              assert_select entry, '> details > blockquote.b270-scripture-library-text[role="tooltip"][tabindex="0"]', count: 1 do |texts|
                assert_equal frame.text, texts.first.text
                assert_equal texts.first['id'], summaries.first['aria-describedby']
              end
            end
          end
          assert_select entry, 'p, script, [title]', count: 0
          refute_includes entry.text, frame.attribution if frame.attribution.present?
        end
      end
    end

    def mount = Bible270.config.mount_at.chomp('/')
    def admin_path = "#{mount}/admin"
    def frames_path = "#{admin_path}/scripture-frames"

    def create_reader(name, admin: false)
      email = "scripture-library-#{name}@example.org"
      Bible270::Reader.create!(provider: 'email', uid: email, email: email, display_name: name, admin: admin)
    end

    def sign_in_as(reader)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"
      assert_response :redirect
    end
  end
end
