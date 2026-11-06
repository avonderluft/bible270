# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class CommunityProgressTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_admins = Bible270.config.admin_emails
      @previous_start_date = Bible270.config.start_date
      @previous_personal_dates = Bible270.config.allow_reader_start_date
      Bible270.config.admin_emails = []
      Bible270.config.start_date = nil
      Bible270.config.allow_reader_start_date = true
      @reader = Bible270::Reader.create!(provider: 'email', uid: 'zoe@example.org',
                                         email: 'zoe@example.org', display_name: 'Zoe Reader')
      @other = Bible270::Reader.create!(provider: 'email', uid: 'amy@example.org',
                                        email: 'amy@example.org', display_name: 'Amy Reader')
    end

    def teardown
      Bible270.config.admin_emails = @previous_admins
      Bible270.config.start_date = @previous_start_date
      Bible270.config.allow_reader_start_date = @previous_personal_dates
      Bible270::Setting.clear_run_start_date!
    end

    def test_signed_in_readers_see_zero_and_half_complete_progress
      @reader.mark_through!(135)
      sign_in

      get "#{mount}/community"

      assert_progress(@other, days: 0, width: 0.0)
      assert_progress(@reader, days: 135, width: 50.0)
      assert_select '.b270-reader-progress span.b270-reader-progress-count', count: 2
      assert_select '.b270-admin-progress, .b270-community-status', count: 0
      assert_select "a[href^='#{mount}/admin/readers/']", count: 0
    end

    def test_finishing_the_plan_shows_270_days_and_a_full_bar
      @other.mark_through!(270)
      sign_in

      get "#{mount}/community"

      assert_progress(@other, days: 270, width: 100.0)
    end

    def test_partial_days_do_not_count_but_nonconsecutive_completed_days_do
      @other.checkoffs.create!(day: 1, track: 'ot', part: 0)
      sign_in
      get "#{mount}/community"
      assert_progress(@other, days: 0, width: 0.0)

      [2, 10, 270].each { |day| @other.mark_day_complete!(day) }
      get "#{mount}/community"

      assert_progress(@other, days: 3, width: 100.0 / 90)
      assert_progress(@reader, days: 0, width: 0.0)
    end

    def test_accessible_progress_label_escapes_the_readers_name
      name = %q{Amy "<script>alert('reader')</script>" & Friends}
      @other.update!(display_name: name)
      sign_in

      get "#{mount}/community"

      assert_progress(@other, days: 0, width: 0.0)
      assert_select '.b270-community-reader-details script', count: 0
      assert_includes response.body, 'aria-label="Amy &quot;&lt;script&gt;'
      refute_includes response.body, name
    end

    def test_today_marker_uses_each_readers_schedule_not_their_completed_days
      Bible270.config.start_date = Bible270.today - 134
      @other.update!(started_on: Bible270.today - 26)
      sign_in

      get "#{mount}/community"

      assert_today_marker(@reader, day: 135, position: 50.0)
      assert_today_marker(@other, day: 27, position: 10.0)
      assert_select '.b270-bar[aria-valuenow="0"]', count: 2
    end

    def test_today_marker_uses_shared_override_when_personal_dates_are_disabled
      Bible270.config.start_date = Bible270.today - 4
      Bible270.config.allow_reader_start_date = false
      @other.update!(started_on: Bible270.today - 26)
      Bible270::Setting.set_run_start_date!(Bible270.today - 134)
      sign_in

      get "#{mount}/community"

      assert_today_marker(@reader, day: 135, position: 50.0)
      assert_today_marker(@other, day: 135, position: 50.0)
    end

    def test_undated_future_and_ended_schedules_have_no_today_marker
      sign_in
      [nil, Bible270.today + 1, Bible270.today - 270].each do |start|
        Bible270.config.start_date = start

        get "#{mount}/community"

        assert_select '.b270-reader-progress', count: 2
        assert_select '.b270-progress-today', count: 0
        assert_select '.b270-bar[aria-valuetext="0 of 270 days complete"]', count: 2
      end
    end

    def test_today_marker_includes_first_and_final_days_and_is_kept_inside_the_bar
      sign_in
      [1, 270].each do |day|
        Bible270.config.start_date = Bible270.today - (day - 1)

        get "#{mount}/community"

        assert_today_marker(@reader, day: day, position: day.fdiv(270) * 100)
        assert_today_marker(@other, day: day, position: day.fdiv(270) * 100)
      end
    end

    def test_today_marker_uses_the_plan_date
      Bible270.config.start_date = Date.new(2026, 9, 1)
      sign_in

      Bible270.stub(:today, Date.new(2026, 9, 27)) { get "#{mount}/community" }

      assert_today_marker(@reader, day: 27, position: 10.0)
    end

    def test_ordinary_community_aggregates_once_without_per_listed_reader_queries
      assert_bulk_progress
    end

    def test_admin_community_aggregates_once_without_per_listed_reader_queries
      Bible270.config.admin_emails = [@reader.email]

      assert_bulk_progress
    end

    def test_preview_community_aggregates_once_without_per_listed_reader_queries
      Bible270.config.admin_emails = [@reader.email]

      assert_bulk_progress(preview: true)
    end

  private

    def mount = Bible270.config.mount_at.chomp('/')

    def sign_in
      _record, raw = Bible270::SignInToken.issue!(@reader.email)
      get "#{mount}/sign_in/email/#{raw}"
    end

    def assert_progress(reader, days:, width:)
      assert_response :success
      assert_select ".b270-community-reader-details .name a[href='#{mount}/readers/#{reader.id}']", count: 1 do |links|
        assert_select links.first.parent.parent, '.b270-reader-progress', count: 1 do
          assert_select '.b270-reader-progress-count', text: "#{days} / 270 days", count: 1
          assert_select '.b270-bar[role="progressbar"]', count: 1 do |bars|
            bar = bars.first
            assert_equal "#{reader.display_name}: reading progress", bar['aria-label']
            assert_equal '0', bar['aria-valuemin']
            assert_equal '270', bar['aria-valuemax']
            assert_equal days.to_s, bar['aria-valuenow']
            description = "#{days} of 270 days complete"
            description += "; today is day #{reader.today_day}" if reader.today_day
            assert_equal description, bar['aria-valuetext']
            assert_select 'i', count: 1 do |fills|
              assert_equal bar, fills.first.parent
              style = fills.first['style']
              assert_match(%r{\Awidth:\s*\d+\.\d+%;?\z}, style)
              assert_in_delta width, style.delete_prefix('width:').to_f, 0.0001
            end
          end
        end
      end
    end

    def assert_today_marker(reader, day:, position:)
      assert_response :success
      assert_select ".b270-community-reader-details .name a[href='#{mount}/readers/#{reader.id}']" do |links|
        assert_select links.first.parent.parent, '.b270-bar', count: 1 do |bars|
          assert_equal "Today: day #{day} of 270", bars.first['title']
          assert_includes bars.first['aria-valuetext'], "; today is day #{day}"
          assert_select '.b270-progress-today[aria-hidden="true"]', count: 1 do |markers|
            assert_equal "left:clamp(0px, #{position}%, calc(100% - 1px))", markers.first['style']
          end
        end
      end
    end

    def assert_bulk_progress(preview: false)
      @reader.mark_through!(135)
      sign_in
      if preview
        patch "#{mount}/admin/view", params: { view: 'reader' }
        assert_response :see_other
      end
      calculations = 0
      aggregate = Bible270::Reader.method(:completed_days_by_id)
      counts = -> do
        calculations += 1
        aggregate.call
      end
      checkoff_queries = []
      subscriber = ->(_name, _start, _finish, _id, payload) do
        checkoff_queries << payload if payload[:sql].match?(%r{SELECT.*bible270_checkoffs}i)
      end

      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        Bible270::Reader.stub(:completed_days_by_id, counts) do
          get "#{mount}/community"
        end
      end

      assert_equal 1, calculations
      bulk, individual = checkoff_queries.partition { |query| query[:sql].match?(%r{GROUP BY.*reader_id}i) }
      assert_equal 1, bulk.size
      # The shared layout loads only the signed-in reader's day grid in addition to the bulk count.
      assert_equal 1, individual.size
      assert_equal [@reader.id], individual.first[:binds].map(&:value_for_database)
      assert_progress(@other, days: 0, width: 0.0)
      assert_progress(@reader, days: 135, width: 50.0)
      assert_select '.b270-community-reader-details .name a' do |names|
        assert_equal ['Amy Reader', 'Zoe Reader'], names.map(&:text),
                     'signed-in community order must be alphabetical, not ranked by progress'
      end
    end
  end
end
