# frozen_string_literal: true

require_relative 'support/admin_reader_view_test_case'

if RAILS_LOADED
  class AdminReaderViewTest < Bible270AdminReaderViewTestCase
    def test_switching_to_reader_and_back_uses_explicit_modes_and_see_other_redirects
      sign_in_as(@admin)
      get "#{mount}/admin"
      assert_full_admin_panel
      assert_view_form('reader')

      switch_view('reader')
      follow_redirect!
      assert_response :success
      assert_admin_tab
      get "#{mount}/admin"
      assert_reader_panel

      switch_view('admin')
      follow_redirect!
      assert_full_admin_panel
      get "#{mount}/admin/readers/#{@reader.id}"
      assert_response :success
    end

    def test_repeating_an_explicit_mode_does_not_toggle_it
      sign_in_as(@admin)

      %w[admin admin reader reader admin admin].each do |view|
        switch_view(view)
        get "#{mount}/admin"
        view == 'reader' ? assert_reader_panel : assert_full_admin_panel
      end
    end

    def test_invalid_or_missing_modes_alert_without_changing_either_state
      sign_in_as(@admin)

      %w[admin reader].each do |view|
        switch_view(view)
        [{ view: 'invalid' }, { view: '' }, {}].each do |params|
          patch "#{mount}/admin/view", params: params

          assert_redirected_to "#{mount}/admin"
          assert flash[:alert].present?, 'invalid modes should explain why nothing changed'
          follow_redirect!
          view == 'reader' ? assert_reader_panel : assert_full_admin_panel
        end
      end
    end

    def test_preview_panel_is_minimal_and_does_not_load_reader_progress
      sign_in_as(@admin)
      switch_view('reader')

      without_community_progress do
        get "#{mount}/admin"
      end

      assert_reader_panel
      assert_select "a[href^='#{mount}/admin/readers/']", count: 0
      assert_select "a[href='#{mount}/admin/comments']", count: 0
      assert_select "form[action^='#{mount}/admin']", count: 1
      assert_select '#b270-reader-stats-dialog, .b270-admin-reader-tools', count: 0
      assert_select "a[href='mailto:#{@reader.email}']", count: 0
    end

    def test_preview_keeps_the_admin_tab_on_reader_pages
      sign_in_as(@admin)
      switch_view('reader')

      ['', '/day/1', '/community', '/reflections', '/progress', '/profile', "/readers/#{@reader.id}"].each do |path|
        get "#{mount}#{path.presence || '/'}"
        assert_response :success
        assert_admin_tab
      end
    end

    def test_preview_keeps_community_progress_but_hides_admin_links_and_status_until_restore
      @reader.mark_through!(135)
      sign_in_as(@admin)
      get "#{mount}/community"
      assert_community_progress
      switch_view('reader')

      get "#{mount}/community"

      assert_response :success
      assert_select '.b270-community-reader-details .b270-reader-progress', count: 2
      assert_select '.b270-reader-progress span.b270-reader-progress-count', text: '135 / 270 days', count: 1
      assert_select '.b270-reader-progress .b270-bar[aria-valuenow="135"] > i[style="width:50.0%"]', count: 1
      assert_select '.b270-admin-progress, .b270-community-status', count: 0
      assert_select "a[href^='#{mount}/admin/readers/']", count: 0
      assert_admin_tab

      switch_view('admin')
      get "#{mount}/community"
      assert_community_progress
    end
  end
end
