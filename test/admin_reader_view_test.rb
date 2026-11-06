# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class AdminReaderViewTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_config = %i[
        admin_emails admin_resolver current_reader_resolver registration_notice_deliver_later
        start_date allow_reader_start_date mention_notifications
      ].to_h { |key| [key, Bible270.config.public_send(key)] }
      Bible270.config.admin_resolver = nil
      Bible270.config.current_reader_resolver = nil
      Bible270.config.registration_notice_deliver_later = false
      Bible270.config.start_date = Bible270.today - 4
      Bible270.config.allow_reader_start_date = true
      Bible270.config.mention_notifications = false
      @admin = create_reader('boss', 'The Boss')
      @reader = create_reader('reader', 'Ordinary Reader')
      Bible270.config.admin_emails = [@admin.email]
      @mine = @admin.comments.create!(day: 1, body: 'My reflection')
      @theirs = @reader.comments.create!(day: 1, body: 'Another reader’s reflection')
      ActionMailer::Base.deliveries.clear
    end

    def teardown
      @previous_config&.each { |key, value| Bible270.config.public_send("#{key}=", value) }
      Bible270::Setting.open_enrollment!
      Bible270::Setting.clear_run_start_date!
    end

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

    def test_community_progress_is_hidden_and_its_bulk_query_is_skipped_until_restore
      sign_in_as(@admin)
      get "#{mount}/community"
      assert_community_progress
      switch_view('reader')

      without_community_progress do
        get "#{mount}/community"
      end
      assert_response :success
      assert_select '.b270-reader-progress, .b270-admin-progress', count: 0
      assert_admin_tab

      switch_view('admin')
      get "#{mount}/community"
      assert_community_progress
    end

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
      assert_select '.b270-reader-progress', count: 0
      assert_equal before, database_snapshot
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

  private

    def mount = Bible270.config.mount_at.chomp('/')

    def create_reader(uid, name)
      email = "admin-reader-view-#{uid}@example.org"
      Bible270::Reader.create!(provider: 'email', uid: email, email: email, display_name: name,
                               first_name: name.split.first, last_name: name.split.last)
    end

    def sign_in_as(reader, browser: self)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      browser.get "#{mount}/sign_in/email/#{raw}"
      browser.assert_response :redirect
    end

    def switch_view(view)
      patch "#{mount}/admin/view", params: { view: view }
      assert_response :see_other
      assert_redirected_to(view == 'reader' ? "#{mount}/" : "#{mount}/admin")
    end

    def assert_admin_tab
      assert_select "a[href='#{mount}/admin']", text: 'Admin', minimum: 1
    end

    def assert_view_form(view)
      assert_select '.b270-admin-view-header > .b270-eyebrow', text: 'Admin', count: 1
      assert_select ".b270-admin-view-header > form[action='#{mount}/admin/view'][method='post']", count: 1 do
        assert_select 'input[name="_method"][value="patch"]', count: 1
        assert_select "[name='view'][value='#{view}']", count: 1
      end
    end

    def assert_reader_panel
      assert_response :success
      assert_admin_tab
      assert_view_form('admin')
      assert_select "form[action='#{mount}/admin/view'] button, form[action='#{mount}/admin/view'] input[type='submit']" do |buttons|
        assert(buttons.any? { |button| (button.name == 'input' ? button['value'] : button.text).strip == 'Return to admin view' })
      end
      assert_select "a[href='#{mount}/admin/readers/#{@reader.id}']", count: 0
    end

    def assert_full_admin_panel
      assert_response :success
      assert_select "a[href='#{mount}/admin/readers/#{@reader.id}']", minimum: 1
    end

    def assert_community_progress
      assert_response :success
      assert_select "a.b270-admin-progress[href='#{mount}/admin/readers/#{@reader.id}']", count: 1
    end

    def assert_comment_controls(comment, count:)
      assert_select "#comment-#{comment.id} .b270-cedit", count: count
      assert_select "#comment-#{comment.id} form[action='#{mount}/comments/#{comment.id}'] .b270-cdel", count: count
    end

    def without_community_progress(&)
      Bible270::Reader.stub(:completed_days_by_id, -> { flunk 'Reader preview must not calculate community progress' }, &)
    end

    def database_snapshot
      [Bible270::Reader, Bible270::Checkoff, Bible270::Comment, Bible270::Setting].to_h do |model|
        [model.name, model.order(:id).map(&:attributes)]
      end
    end
  end
end
