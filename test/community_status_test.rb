# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class CommunityStatusTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_admins = Bible270.config.admin_emails
      @previous_start_date = Bible270.config.start_date
      @previous_personal_dates = Bible270.config.allow_reader_start_date
      Bible270.config.start_date = Bible270.today - 4
      Bible270.config.allow_reader_start_date = true
      @reader = Bible270::Reader.create!(provider: 'email', uid: 'reader@example.org',
                                         email: 'reader@example.org', display_name: 'Reader')
      @admin = Bible270::Reader.create!(provider: 'email', uid: 'admin@example.org',
                                        email: 'admin@example.org', display_name: 'Admin')
      Bible270.config.admin_emails = [@admin.email]
    end

    def teardown
      Bible270.config.admin_emails = @previous_admins
      Bible270.config.start_date = @previous_start_date
      Bible270.config.allow_reader_start_date = @previous_personal_dates
    end

    def test_admin_sees_two_days_behind_after_the_completed_day_link
      assert_admin_status(days: 3, status: '2 days behind')
    end

    def test_admin_sees_singular_behind
      assert_admin_status(days: 4, status: '1 day behind')
    end

    def test_admin_sees_on_track
      assert_admin_status(days: 5, status: 'on track')
    end

    def test_admin_sees_singular_ahead
      assert_admin_status(days: 6, status: '1 day ahead')
    end

    def test_admin_sees_plural_ahead
      assert_admin_status(days: 7, status: '2 days ahead')
    end

    def test_admin_sees_undated_without_a_start_date
      Bible270.config.start_date = nil

      assert_admin_status(days: 0, status: 'undated')
    end

    def test_status_uses_the_readers_personal_date
      @reader.set_start_date!(Bible270.today - 1)

      assert_admin_status(days: 3, status: '1 day ahead')
    end

    def test_status_ignores_personal_dates_when_disabled
      @reader.set_start_date!(Bible270.today - 1)
      Bible270.config.allow_reader_start_date = false

      assert_admin_status(days: 3, status: '2 days behind')
    end

    def test_status_uses_preloaded_counts_without_per_reader_aggregation
      sign_in_as(@admin)
      calculations = 0
      counts = -> do
        calculations += 1
        Hash.new(0).merge(@reader.id => 3)
      end
      checkoff_queries = []
      subscriber = ->(_name, _start, _finish, _id, payload) do
        checkoff_queries << payload if payload[:sql].match?(%r{SELECT COUNT.*bible270_checkoffs}i)
      end

      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        Bible270::Reader.stub(:completed_days_by_id, counts) do
          get "#{mount}/community"
        end
      end

      assert_equal 1, calculations
      # The shared layout still loads the signed-in admin's day grid, not each listed reader's progress.
      assert_equal 1, checkoff_queries.size
      assert_equal [@admin.id], checkoff_queries.first[:binds].map(&:value_for_database)
      assert_completed_status(days: 3, status: '2 days behind')
      assert_select "a.b270-admin-progress[href='#{mount}/admin/readers/#{@admin.id}']", text: '0 of 270 days complete'
    end

    def test_ordinary_reader_sees_no_status_or_completed_day_link
      sign_in_as(@reader)

      assert_no_community_status
    end

    def test_visitor_sees_no_status_or_completed_day_link
      assert_no_community_status
    end

  private

    def mount = Bible270.config.mount_at.chomp('/')

    def sign_in_as(reader)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"
    end

    def assert_admin_status(days:, status:)
      @reader.mark_through!(days)
      sign_in_as(@admin)

      get "#{mount}/community"

      assert_completed_status(days: days, status: status)
    end

    def assert_completed_status(days:, status:)
      assert_response :success
      assert_select "a.b270-admin-progress[href='#{mount}/admin/readers/#{@reader.id}']",
                    text: "#{days} of 270 days complete", count: 1 do |links|
        assert_match(%r{#{days} of 270 days complete\s+· #{Regexp.escape(status)}\s*\z}, links.first.parent.text)
      end
    end

    def assert_no_community_status
      Bible270::Reader.stub(:completed_days_by_id, -> { flunk 'Non-admin requests must not calculate progress' }) do
        get "#{mount}/community"
      end

      assert_response :success
      assert_select '.b270-admin-progress', count: 0
      assert_select '.b270-li .sub', text: %r{\Ajoined [A-Z][a-z]{2} \d{1,2} \d{4}\z}, count: 2
      assert_select '.b270-li .sub', text: %r{ahead|behind|on track|undated}, count: 0
    end
  end
end
