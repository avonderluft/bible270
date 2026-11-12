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

    def test_main_admin_has_header_only_native_disclosures_with_described_tooltips
      [@admin, @site_admin].each do |admin|
        sign_in_as(admin)
        get admin_path

        assert_response :success
        assert_select '#b270-alumni + section#b270-scripture-frames', count: 1
        assert_select '#b270-scripture-frames + p a', text: '← Back to the plan'
        assert_select '#b270-scripture-frames' do
          assert_select "a[href='#{frames_path}']", text: 'Manage texts'
          assert_select "a[href='#{frames_path}/new']", text: 'Add text'
          assert_select 'script, form, [title], .b270-scripture-art, .b270-scripture-art__attribution', count: 0
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
      assert_match(%r{\.b270-scripture-library-disclosure:hover>\.b270-scripture-library-text,\s*\.b270-scripture-library-disclosure:focus-within>\.b270-scripture-library-text\{display:block\}}, styles)
      assert_match(%r{\.b270-scripture-library-disclosure>\.b270-scripture-library-text\{[^\}]*width:min\(32rem,100%\);max-height:50vh;max-height:50dvh;overflow:auto}, styles)
      assert_match(%r{\.b270-scripture-library-text\{[^\}]*white-space:pre-wrap;overflow-wrap:anywhere}, styles)
      assert_includes styles, '.b270-scripture-library-text:focus-visible{outline:2px solid var(--gold);outline-offset:2px}'
      assert_includes styles, 'background:var(--paper);background:color-mix(in srgb,var(--card) 90%,var(--gold))'
      assert_includes styles, '.b270-scripture-library-disclosure[open]>.b270-scripture-library-text{position:relative;inset:auto;width:100%;margin-top:8px}'
      assert_includes styles, 'details.b270-alumni{margin-bottom:24px}'
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
        assert_select "a[href='#{frames_path}']", text: 'Manage texts'
        assert_select "a[href='#{frames_path}/new']", count: 0
        assert_select 'article[data-source="custom"]', count: 0
        assert_library_entries(Bible270::ScriptureFrames.defaults, source: 'default')
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

    def test_manage_texts_starts_with_add_then_compact_custom_and_default_lists
      get frames_path

      assert_response :success
      assert_select '.b270-admin-view-header + h1', text: 'Scripture frames'
      assert_select ".b270-admin-view-header a[href='#{frames_path}/new']", text: 'Add text'
      assert_select "a[href='#{frames_path}/new']", count: 1
      assert_select '#b270-custom-scripture-texts + #b270-default-scripture-texts', count: 1
      assert_select '#b270-custom-scripture-texts' do
        assert_select 'h2', text: 'Custom texts'
        assert_select 'section.b270-scripture-library-entry', count: 2
        assert_select 'details.b270-scripture-library-disclosure:not([open])', count: 2
        assert_select '.b270-scripture-actions', count: 2
        assert_select 'blockquote' do |passages|
          assert_equal [@frame.text, @disabled.text], passages.map(&:text).to_a
        end
      end
      assert_select '#b270-default-scripture-texts' do
        assert_select 'h2', text: 'Default texts'
        assert_select 'details.b270-scripture-library-disclosure:not([open])', count: Bible270::ScriptureFrames.defaults.size
        assert_select 'form, .b270-scripture-actions', count: 0
      end
      assert_select '#b270-custom-scripture-texts .b270-scripture-art, #b270-default-scripture-texts .b270-scripture-art, .b270-scripture-library-entry [data-b270-scripture-attribution]', count: 0
      ids = css_select('.b270-scripture-library-text').map { |entry| entry['id'] }
      assert_equal ids.uniq, ids
    end

  private

    def assert_library_entries(frames, source:)
      assert_select 'article[data-source=?]', source, count: frames.length do |entries|
        entries.zip(frames).each do |entry, frame|
          disabled = source == 'custom' && !frame.enabled? ? ' · Disabled' : ''
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
