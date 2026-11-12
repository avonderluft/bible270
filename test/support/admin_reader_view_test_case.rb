# frozen_string_literal: true

require_relative '../test_helper'

if RAILS_LOADED
  class Bible270AdminReaderViewTestCase < ActionDispatch::IntegrationTest
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
      assert_select '.b270-community-reader-details .b270-reader-progress', minimum: 2
      assert_select "a.b270-reader-progress-count.b270-admin-progress[href='#{mount}/admin/readers/#{@reader.id}']", count: 1
      assert_select '.b270-reader-progress + .sub.b270-community-status', minimum: 2
    end

    def assert_comment_controls(comment, count:)
      assert_select "#comment-#{comment.id} .b270-cedit", count: count
      assert_select "#comment-#{comment.id} form[action='#{mount}/comments/#{comment.id}'] .b270-cdel", count: count
    end

    def without_community_progress(&)
      Bible270::Reader.stub(:completed_days_by_id, -> { flunk 'The minimal admin preview panel must not calculate progress' }, &)
    end

    def database_snapshot
      [Bible270::Reader, Bible270::Checkoff, Bible270::Comment, Bible270::Setting].to_h do |model|
        [model.name, model.order(:id).map(&:attributes)]
      end
    end
  end
end
