# frozen_string_literal: true

require_relative 'support/admin_reader_view_test_case'

if RAILS_LOADED
  class AdminReaderViewAuthorizationTest < Bible270AdminReaderViewTestCase
    def test_visitors_cannot_select_either_view
      %w[reader admin].each do |view|
        patch "#{mount}/admin/view", params: { view: view }
        assert_response :not_found
      end
    end

    def test_ordinary_readers_cannot_select_either_view_or_see_the_admin_tab
      sign_in_as(@reader)
      before = database_snapshot

      %w[reader admin].each do |view|
        patch "#{mount}/admin/view", params: { view: view }
        assert_response :not_found
      end

      assert_equal before, database_snapshot
      get "#{mount}/admin"
      assert_response :not_found
      get "#{mount}/community"
      assert_response :success
      assert_select "a[href='#{mount}/admin']", count: 0
    end

    def test_preview_cannot_patch_or_delete_another_authors_reflection
      sign_in_as(@admin)
      switch_view('reader')
      before = database_snapshot

      patch "#{mount}/comments/#{@theirs.id}", params: { comment: { body: 'Hijacked' } }
      assert_response :not_found
      assert_equal before, database_snapshot
      delete "#{mount}/comments/#{@theirs.id}"
      assert_response :not_found
      assert_equal before, database_snapshot

      switch_view('admin')
      patch "#{mount}/comments/#{@theirs.id}", params: { comment: { body: 'Moderated' } }
      assert_response :redirect
      assert_equal 'Moderated', @theirs.reload.body
      assert_difference('Bible270::Comment.count', -1) do
        delete "#{mount}/comments/#{@theirs.id}"
      end
      assert_response :redirect
    end

    def test_all_other_admin_routes_are_denied_without_database_changes_or_mail
      sign_in_as(@admin)
      @reader.mark_day_complete!(1)
      hidden = @reader.comments.create!(day: 1, body: 'Hidden reflection')
      hidden.hide!
      Bible270::Setting.set_run_start_date!(Bible270.today - 3)
      switch_view('reader')
      before = database_snapshot
      reader_path = "#{mount}/admin/readers/#{@reader.id}"
      requests = [
        [:get, reader_path, {}],
        [:get, "#{mount}/admin/comments", {}],
        [:patch, "#{reader_path}/profile", { first_name: 'Changed', last_name: 'Name' }],
        [:patch, "#{reader_path}/theme", { display_mode: 'mist' }],
        [:patch, "#{reader_path}/notifications", { comment_notifications: 'none' }],
        [:patch, "#{reader_path}/completion-animation", { completion_dove_disabled: '1' }],
        [:delete, "#{reader_path}/avatar", {}],
        [:patch, "#{reader_path}/version", { bible_version: 'KJV' }],
        [:patch, "#{reader_path}/start", { start_date: '2026-01-01' }],
        [:patch, "#{reader_path}/through", { day: '3' }],
        [:post, "#{reader_path}/days/2", {}],
        [:patch, "#{mount}/admin/enrollment", { state: 'closed' }],
        [:patch, "#{mount}/admin/run-start", { start_date: '2026-01-01' }],
        [:delete, "#{mount}/admin/run-start", {}],
        [:post, "#{mount}/admin/broadcast", { subject: 'No mail', body: 'Must not be sent' }],
        [:patch, "#{mount}/admin/comments/#{@theirs.id}/hide", {}],
        [:patch, "#{mount}/admin/comments/#{hidden.id}/unhide", {}],
        [:delete, "#{mount}/admin/comments/#{@theirs.id}", {}],
        [:delete, reader_path, {}]
      ]

      requests.each do |method, path, params|
        public_send(method, path, params: params)
        assert_response :not_found, "#{method.upcase} #{path} must be denied in reader view"
        assert_equal before, database_snapshot, "#{method.upcase} #{path} must not change stored data"
        assert_empty ActionMailer::Base.deliveries
      end
    end

    def test_admin_resolver_is_honored_and_revocation_prevents_restoring
      Bible270.config.admin_emails = []
      Bible270.config.admin_resolver = ->(reader) { reader.id == @admin.id }
      sign_in_as(@admin)
      switch_view('reader')
      switch_view('admin')
      get "#{mount}/admin"
      assert_full_admin_panel
      switch_view('reader')

      Bible270.config.admin_emails = [@admin.email]
      Bible270.config.admin_resolver = ->(_reader) { false }
      before = database_snapshot
      %w[admin reader].each do |view|
        patch "#{mount}/admin/view", params: { view: view }
        assert_response :not_found
      end
      get "#{mount}/admin"
      assert_response :not_found
      get "#{mount}/community"
      assert_response :success
      assert_select "a[href='#{mount}/admin']", count: 0
      assert_select '.b270-reader-progress span.b270-reader-progress-count', text: '0 / 270 days', count: 2
      assert_select '.b270-admin-progress, .b270-community-status', count: 0
      assert_select "a[href^='#{mount}/admin/readers/']", count: 0
      assert_equal before, database_snapshot
    end
  end
end
