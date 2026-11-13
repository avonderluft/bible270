# frozen_string_literal: true

require_relative 'support/admin_reader_view_test_case'

if RAILS_LOADED
  class AdminReaderViewControlsSessionsTest < Bible270AdminReaderViewTestCase
    def test_preview_hides_other_authors_controls_but_keeps_own_controls_and_restores_them
      sign_in_as(@admin)
      get "#{mount}/day/1"
      assert_comment_controls(@theirs, count: 1)
      switch_view('reader')

      ["#{mount}/day/1", "#{mount}/reflections", "#{mount}/readers/#{@reader.id}"].each do |path|
        get path
        assert_response :success
        assert_select "#comment-#{@theirs.id}", count: 1
        assert_comment_controls(@theirs, count: 0)
      end

      get "#{mount}/day/1", params: { edit: @theirs.id }
      assert_select 'form.b270-editform', count: 0
      assert_comment_controls(@mine, count: 1)
      get "#{mount}/day/1", params: { edit: @mine.id }
      assert_select "form.b270-editform[action='#{mount}/comments/#{@mine.id}']", count: 1

      switch_view('admin')
      get "#{mount}/day/1"
      assert_comment_controls(@theirs, count: 1)
      get "#{mount}/day/1", params: { edit: @theirs.id }
      assert_select "form.b270-editform[action='#{mount}/comments/#{@theirs.id}']", count: 1
    end

    def test_own_reflections_and_checkoffs_still_work_in_preview
      sign_in_as(@admin)
      switch_view('reader')

      assert_difference('@admin.comments.count', 1) do
        post "#{mount}/day/1/comments", params: { comment: { body: 'An ordinary reader action' } }
      end
      assert_response :redirect
      patch "#{mount}/comments/#{@mine.id}", params: { comment: { body: 'My revised reflection' } }
      assert_response :redirect
      assert_equal 'My revised reflection', @mine.reload.body
      assert_difference('@admin.comments.count', -1) do
        delete "#{mount}/comments/#{@mine.id}"
      end
      assert_response :redirect

      assert_difference('@admin.checkoffs.count', 1) do
        post "#{mount}/day/1/toggle/nt/0", params: { checked: '1' }
      end
      assert_response :redirect
      assert @admin.checkoffs.exists?(day: 1, track: 'nt', part: 0)
      assert_equal 0, @reader.checkoffs.count
      get "#{mount}/admin"
      assert_reader_panel
    end

    def test_switching_changes_neither_configuration_nor_database_records
      sign_in_as(@admin)
      before = database_snapshot
      config_before = @previous_config.keys.to_h do |key|
        value = Bible270.config.public_send(key)
        [key, value.is_a?(Array) ? value.dup : value]
      end

      %w[reader reader admin admin].each do |view|
        switch_view(view)
        assert_equal before, database_snapshot
        config_after = config_before.keys.to_h { |key| [key, Bible270.config.public_send(key)] }
        assert_equal config_before, config_after
        assert Bible270.config.admin?(@admin.reload), 'preview must not revoke the actual administrator role'
      end
    end

    def test_signing_out_and_back_in_clears_preview
      sign_in_as(@admin)
      switch_view('reader')
      delete "#{mount}/sign_out"
      assert_response :redirect
      patch "#{mount}/admin/view", params: { view: 'admin' }
      assert_response :not_found

      sign_in_as(@admin)
      get "#{mount}/admin"
      assert_full_admin_panel
      get "#{mount}/community"
      assert_community_progress
    end

    def test_signing_in_again_without_signing_out_also_clears_preview
      sign_in_as(@admin)
      switch_view('reader')
      sign_in_as(@admin)

      get "#{mount}/admin"
      assert_full_admin_panel
    end

    def test_a_second_browser_for_the_same_admin_is_unaffected
      sign_in_as(@admin)
      second_browser = open_session
      sign_in_as(@admin, browser: second_browser)
      switch_view('reader')

      second_browser.get "#{mount}/community"
      second_browser.assert_response :success
      second_browser.assert_select '.b270-admin-progress', minimum: 1
      second_browser.get "#{mount}/admin/readers/#{@reader.id}"
      second_browser.assert_response :success
      second_browser.patch "#{mount}/admin/view", params: { view: 'admin' }
      second_browser.assert_response :see_other

      get "#{mount}/admin"
      assert_reader_panel
    end

    def test_preview_does_not_survive_loss_of_the_session_even_with_a_remember_cookie
      sign_in_as(@admin)
      switch_view('reader')
      remembered = cookies[:bible270_remember]
      assert remembered.present?
      reset!
      cookies[:bible270_remember] = remembered

      get "#{mount}/admin"
      assert_full_admin_panel
    end

    def test_host_resolver_switching_readers_does_not_transfer_preview
      other_admin = create_reader('other-boss', 'Other Boss')
      Bible270.config.admin_emails = [@admin.email, other_admin.email]
      resolved_reader = @admin
      Bible270.config.current_reader_resolver = ->(_controller) { resolved_reader }
      switch_view('reader')
      get "#{mount}/admin"
      assert_reader_panel

      resolved_reader = other_admin
      get "#{mount}/admin"
      assert_full_admin_panel
      get "#{mount}/community"
      assert_community_progress

      resolved_reader = @reader
      patch "#{mount}/admin/view", params: { view: 'admin' }
      assert_response :not_found
      get "#{mount}/admin"
      assert_response :not_found
    end
  end
end
