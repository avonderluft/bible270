# frozen_string_literal: true

require_relative 'support/admin_scripture_frames_test_case'
require 'net/http'

if RAILS_LOADED
  class AdminScripturePreviewTest < Bible270AdminScriptureFramesTestCase
    def test_admins_share_one_accessible_blank_native_dialog_after_the_library
      [@admin, @site_admin].each do |admin|
        sign_in_as(admin)
        get admin_path

        assert_response :success
        assert_select '#b270-scripture-preview', count: 1
        assert_select 'dialog#b270-scripture-preview:not([open])', count: 1 do |dialogs|
          dialog = dialogs.first
          assert_empty dialog.ancestors('#b270-scripture-frames, article, details')
          assert dialog.xpath('preceding::*[@id="b270-scripture-frames"]').any?, 'Preview dialog must follow the library'
          label = dialog['aria-label'].presence || css_select("##{dialog['aria-labelledby']}").map(&:text).join
          assert_match(%r{scripture.*preview}i, label)
          assert_select 'form[method="dialog"] button[type="submit"]', count: 1 do |buttons|
            assert_match(%r{close}i, buttons.first['aria-label'].presence || buttons.first.text)
          end
          assert_select 'figure.b270-scripture-art[data-b270-scripture-art][hidden]', count: 1 do |frames|
            shared_frame = Bible270::ApplicationController.render(partial: 'bible270/shared/scripture_frame', locals: { frame: nil })
            assert_dom_equal shared_frame, frames.first.to_html
            assert_select '.b270-scripture-art__mat > blockquote.b270-scripture-art__verse > p[data-b270-scripture-text]', count: 1
            assert_select 'figcaption.b270-scripture-art__caption', count: 1
            %w[reference translation text attribution].each do |field|
              assert_select "[data-b270-scripture-#{field}]", count: 1 do |nodes|
                assert_empty nodes.first.text
                assert_empty nodes.first.element_children
              end
            end
            assert_select '[data-b270-scripture-attribution][hidden]', count: 1
          end
        end
        assert_select '#b270-scripture-frames [data-b270-scripture-art], #b270-scripture-frames dialog', count: 0
        assert_select 'script[data-b270-scripture-preview-ui]', count: 1 do |scripts|
          assert_empty scripts.first.ancestors('#b270-scripture-frames, article')
          assert scripts.first.xpath('preceding::*[@id="b270-scripture-preview"]').any?
        end
        css_select('#b270-scripture-preview, #b270-scripture-preview [id]').each do |node|
          assert_select '[id=?]', node['id'], count: 1
        end
      end
    end

    def test_custom_and_host_catalog_preview_payloads_preserve_quotes_and_escape_html
      reference = 'An "author" & <script>previewAttack()</script>'
      text = "First 'quoted' line & more\n\" onmouseover=\"previewAttack()\n</button><img src=x onerror=previewAttack()>\n**Not Markdown**"
      translation = 'HOST"<&'
      attribution = 'Credit " onfocus="previewAttack() & <script>previewAttack()</script>'
      path = File.join(@directory, 'preview-frames.yml')
      File.write(path, YAML.dump([{ 'id' => 'preview-example', 'reference' => reference, 'text' => text,
                                    'translation' => translation, 'attribution' => attribution }]))
      Bible270.config.scripture_frames_path = path
      @frame.update!(reference: reference, text: text, translation: translation)
      sign_in_as(@admin)

      get admin_path

      assert_response :success
      { 'custom' => @frame, 'default' => Bible270::ScriptureFrames.defaults.first }.each do |source, frame|
        assert_select "#b270-scripture-frames article[data-source='#{source}']", count: 1 do |entries|
          assert_scripture_preview_button(entries.first, frame)
          assert_select 'blockquote.b270-scripture-library-text', count: 1 do |passages|
            assert_equal text, passages.first.text
            assert_empty passages.first.element_children
          end
          assert_select 'script, img, [onmouseover], [onfocus], [onerror]', count: 0
          refute_includes entries.first.text, attribution
        end
      end
      assert_includes response.body, '&lt;script&gt;previewAttack()&lt;/script&gt;'
      css_select('script').each { |script| refute_includes script.text, 'previewAttack' }
      assert_select '#b270-scripture-preview [data-b270-scripture-text]', text: '', count: 1
    end

    def test_disabled_quotations_have_other_payload_without_a_stale_bible_credit
      quotation = Bible270::ScriptureFrame.create!(
        reference: 'An "author" <name>', translation: 'OTHER', text: "A quotation.\nSecond line & more.", enabled: false
      )
      quotation.update_column(:attribution, 'Stale Bible credit must not be previewed.')
      sign_in_as(@admin)

      get admin_path

      assert_response :success
      assert_select '#b270-custom-scripture-texts article' do |entries|
        entry = entries.find { |node| node['aria-label'] == "Custom text: #{quotation.reference}" }
        refute_nil entry
        assert_scripture_preview_button(entry, quotation)
        assert_select entry, 'summary', text: "#{quotation.reference} · Other quotation · Custom · Disabled"
        assert_select entry, 'button[data-b270-scripture-preview][data-b270-preview-translation="OTHER"][data-b270-preview-attribution=""]', count: 1
        refute_includes entry.to_html, 'Stale Bible credit'
      end
    end

    def test_public_domain_and_uncredited_catalog_entries_keep_empty_attribution_payloads
      use_host_translation(attribution: nil)
      @frame.update!(translation: 'KJV')
      sign_in_as(@admin)

      get admin_path

      assert_response :success
      assert_select '#b270-scripture-frames' do
        assert_library_entries([@frame], source: 'custom')
        assert_library_entries(Bible270::ScriptureFrames.defaults, source: 'default')
        assert_select 'button[data-b270-scripture-preview][data-b270-preview-attribution=""]', count: 2
      end
    end

    def test_rendering_preview_controls_does_not_fetch_select_or_advance_frames
      sign_in_as(@admin)
      Bible270::ScriptureFrames.set_default_enabled!(Bible270::ScriptureFrames.defaults.first.id, enabled: false)
      @frame.update!(enabled: false)
      state = { 'version' => 1, 'catalog' => 'a' * 64, 'seed' => '0123456789abcdef',
                'cursor' => 1, 'deferred' => [], 'last' => 'b' * 64 }
      @admin.update_column(:scripture_frame_rotation, state)
      rotations = Bible270::Reader.order(:id).pluck(:id, :scripture_frame_rotation)
      frames = Bible270::ScriptureFrame.order(:id).map(&:attributes)
      settings = Bible270::Setting.order(:id).map(&:attributes)
      forbidden = ->(*) { flunk 'Stored Preview must not fetch or select a Scripture frame' }

      Net::HTTP.stub(:new, forbidden) do
        Net::HTTP.stub(:start, forbidden) do
          Bible270::ScriptureFrames.stub(:random, forbidden) do
            Bible270::ScriptureFrameRotation.stub(:select, forbidden) do
              2.times do
                get admin_path
                assert_response :success
                assert_select '#b270-scripture-frames' do
                  assert_select 'article', count: Bible270::ScriptureFrames.defaults.length + 1
                  assert_select '[data-b270-scripture-art]', count: 0
                end
                visit_legacy_library
              end
            end
          end
        end
      end

      assert_equal rotations, Bible270::Reader.order(:id).pluck(:id, :scripture_frame_rotation)
      assert_equal frames, Bible270::ScriptureFrame.order(:id).map(&:attributes)
      assert_equal settings, Bible270::Setting.order(:id).map(&:attributes)
    end

    def test_visitors_cannot_obtain_preview_payloads_by_forging_admin_parameters
      get admin_path, params: { view: 'admin', admin: true, site_admin: true }

      assert_response :not_found
      assert_preview_hidden
    end

    def test_readers_and_alumni_cannot_obtain_preview_payloads
      sign_in_as(@reader)
      2.times do |index|
        @reader.archive! if index == 1
        get admin_path, params: { view: 'admin', admin: true, site_admin: true }

        assert_response :not_found
        assert_preview_hidden
      end
    end

    def test_alumni_admins_can_preview_without_reactivation
      [@admin, @site_admin].each do |admin|
        admin.archive!
        before = admin.participation.attributes
        sign_in_as(admin)

        get admin_path

        assert_response :success
        assert_select '#b270-scripture-preview', count: 1
        assert_select '#b270-scripture-frames' do
          assert_library_entries([@frame], source: 'custom')
          assert_library_entries(Bible270::ScriptureFrames.defaults, source: 'default')
        end
        assert admin.reload.alumni?
        assert_equal before, admin.participation.reload.attributes
      end
    end

  private

    def assert_preview_hidden
      assert_select '#b270-scripture-frames, #b270-scripture-preview, [data-b270-scripture-preview], script[data-b270-scripture-preview-ui]', count: 0
      refute_includes response.body, @frame.text
    end
  end
end
