# frozen_string_literal: true

require_relative '../test_helper'
require_relative 'scripture_frame_fixtures'

if RAILS_LOADED
  module Bible270AdminScripturePreviewAssertions
    def assert_scripture_preview_button(entry, frame)
      assert_equal %w[details div], entry.element_children.map(&:name)
      assert_select entry, '> details + div.b270-scripture-actions', count: 1 do |actions|
        assert_select '> button.b270-linkbtn[data-b270-scripture-preview]', text: 'Preview', count: 1 do |buttons|
          button = buttons.first
          assert_equal button, actions.first.element_children.first, 'Preview must be the first action'
          assert_equal 'button', button['type']
          assert_equal "Preview #{frame.reference}", button['aria-label']
          assert_equal 'dialog', button['aria-haspopup']
          assert_equal 'b270-scripture-preview', button['aria-controls']
          %i[reference translation text attribution].each do |field|
            assert_equal frame.public_send(field).to_s, button["data-b270-preview-#{field}"], "Preview #{field} must preserve stored plaintext"
          end
          assert_empty button.element_children
          assert_empty button.ancestors('form, summary')
        end
      end
      assert_select entry, '[data-b270-scripture-art], .b270-scripture-art, dialog', count: 0
    end
  end

  class Bible270AdminScriptureFramesTestCase < ActionDispatch::IntegrationTest
    include Bible270AdminScripturePreviewAssertions

    def setup
      needs_rails!
      clear_engine_tables!
      Bible270::ScriptureFrame.delete_all
      @previous_config = %i[
        admin_emails admin_resolver current_reader_resolver registration_notice_deliver_later scripture_frames_path layout
      ].to_h { |key| [key, Bible270.config.public_send(key)] }
      Bible270.config.admin_resolver = nil
      Bible270.config.current_reader_resolver = nil
      Bible270.config.registration_notice_deliver_later = false
      Bible270.config.scripture_frames_path = ScriptureFrameFixtures::CATALOG_PATH

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

  private

    def assert_library_entries(frames, source:)
      assert_select 'article[data-source=?]', source, count: frames.length do |entries|
        entries.zip(frames).each do |entry, frame|
          enabled = source == 'custom' ? frame.enabled? : !Bible270::ScriptureFrames.disabled_default_ids.include?(frame.id)
          disabled = enabled ? '' : ' · Disabled'
          label = source == 'custom' ? 'Custom text' : 'Bundled text'
          assert_equal "#{label}: #{frame.reference}", entry['aria-label']
          assert_scripture_preview_button(entry, frame)
          assert_select entry, '> details.b270-scripture-library-disclosure:not([open])', count: 1
          translation = Bible270::ScriptureFrames.quotation?(frame.translation) ? 'Other quotation' : frame.translation
          assert_select entry, 'summary', text: "#{frame.reference} · #{translation} · #{source.capitalize}#{disabled}"
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
