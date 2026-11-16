# frozen_string_literal: true

require_relative 'support/admin_scripture_frames_test_case'

if RAILS_LOADED
  class AdminScriptureFrameAuthorizationTest < Bible270AdminScriptureFramesTestCase
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

    def test_pending_migration_does_not_expose_endpoints_to_readers
      sign_in_as(@reader)
      Bible270::ScriptureFrames.stub(:custom_available?, false) { assert_all_requests_hidden }
    end
  end
end
