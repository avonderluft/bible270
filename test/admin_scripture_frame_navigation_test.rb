# frozen_string_literal: true

require_relative 'support/admin_scripture_frames_test_case'

if RAILS_LOADED
  class AdminScriptureFrameNavigationTest < Bible270AdminScriptureFramesTestCase
    def test_legacy_index_redirects_both_admin_roles_directly_to_the_panel_with_a_sanitized_sort
      # Catalog tests cover the full page; this matrix checks routing and return context.
      Bible270.config.layout = false
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
  end
end
