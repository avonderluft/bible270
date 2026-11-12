# frozen_string_literal: true

require_relative 'support/admin_controller_test_case'

if RAILS_LOADED
  class AdminReaderListingTest < Bible270AdminControllerTestCase
    def test_an_admin_sees_the_reader_list
      sign_in_as_admin
      get "#{mount}/admin"

      assert_response :success
      assert_match(%r{R Reader}, response.body)
      assert_select "a[aria-label='R Reader'][href='#{mount}/admin/readers/#{@reader.id}'] .b270-avatar", count: 1
      assert_select "a[href='mailto:#{@reader.email}']", text: @reader.email
    end

    def test_the_reader_list_shows_start_date_then_days_completed_then_status
      Bible270.config.start_date = Bible270.today - 9
      Bible270.config.allow_reader_start_date = false
      sign_in_as_admin
      start_date = Bible270.config.start_date.strftime('%b %-d, %Y')

      { 0 => '10 days behind', 9 => '1 day behind', 10 => 'on track',
        11 => '1 day ahead', 12 => '2 days ahead' }.each do |days, status|
        @reader.mark_through!(days) if days.positive?

        get "#{mount}/admin"

        details = css_select(".b270-list a[href='mailto:#{@reader.email}']").first.parent.text.squish
        assert_equal "#{@reader.email} · started #{start_date} · #{days}/270 days · #{status}", details
      end
    end

    def test_the_reader_list_status_uses_the_readers_personal_start_date
      Bible270.config.start_date = Bible270.today - 9
      Bible270.config.allow_reader_start_date = true
      @reader.update!(started_on: Bible270.today - 1)
      @reader.mark_through!(3)
      sign_in_as_admin

      get "#{mount}/admin"

      start_date = @reader.started_on.strftime('%b %-d, %Y')
      details = css_select(".b270-list a[href='mailto:#{@reader.email}']").first.parent.text.squish
      assert_equal "#{@reader.email} · started #{start_date} · 3/270 days · 1 day ahead", details
    end

    def test_the_reader_list_shows_undated_without_a_start_date
      Bible270.config.start_date = nil
      Bible270.config.allow_reader_start_date = false
      sign_in_as_admin

      get "#{mount}/admin"

      details = css_select(".b270-list a[href='mailto:#{@reader.email}']").first.parent.text.squish
      assert_equal "#{@reader.email} · 0/270 days · undated", details
    end

    def test_the_reader_list_shows_each_readers_latest_reading_activity
      completed_at = Time.utc(2026, 9, 15, 18)
      @reader.mark_day_complete!(7)
      @reader.checkoffs.where(day: 7).update_all(created_at: completed_at)

      partial_reader = Bible270::Reader.create!(provider: 'email', uid: 'partial@example.org',
                                                email: 'partial@example.org', display_name: 'Partial Reader')
      partial_at = Time.utc(2026, 9, 16, 18)
      partial_checkoff = partial_reader.checkoffs.create!(day: 13, track: 'ot', part: 0)
      partial_checkoff.update_column(:created_at, partial_at)

      sign_in_as_admin
      get "#{mount}/admin"

      completed_tooltip = Bible270::Plan.readings_for(7).values.compact.join(' · ')
      completed_date = Bible270.local_time(completed_at).strftime('%b %-d, %Y %H:%M')
      partial_reference = Bible270::Plan.parts_for(13, 'ot').first
      partial_tooltip = Bible270::Plan.readings_for(13).values.compact.join(' · ')
      partial_date = Bible270.local_time(partial_at).strftime('%b %-d, %Y %H:%M')

      assert_select '.b270-reader-activity', count: 3
      assert_select '.b270-reader-activity', text: "#{completed_date}: completed Day 7"
      assert_select ".b270-reader-activity a[href='#{mount}/day/7'][title='#{completed_tooltip}']", text: 'Day 7'
      assert_select '.b270-reader-activity', text: "#{partial_date}: checked off “#{partial_reference}” for Day 13"
      assert_select ".b270-reader-activity a[href='#{mount}/day/13'][title='#{partial_tooltip}']", text: 'Day 13'
      assert_select '.b270-reader-activity', text: 'No reading activity yet', count: 1
    end

    # The community page lists people by first name, so the admin list should too:
    # surname order read oddly beside names displayed first-name-first.
    def test_the_reader_list_is_ordered_by_first_name
      Bible270::Reader.create!(provider: 'email', uid: 'z@example.org', email: 'z@example.org',
                               display_name: 'Aaron Zebedee', first_name: 'Aaron', last_name: 'Zebedee')
      Bible270::Reader.create!(provider: 'email', uid: 'y@example.org', email: 'y@example.org',
                               display_name: 'Zeke Aaronson', first_name: 'Zeke', last_name: 'Aaronson')
      sign_in_as_admin

      get "#{mount}/admin"

      assert_response :success
      assert_operator response.body.index('Aaron Zebedee'), :<, response.body.index('Zeke Aaronson'),
                      'Aaron should precede Zeke, despite Zebedee following Aaronson'
    end

    def test_the_reader_list_offers_all_sort_options
      sign_in_as_admin

      get "#{mount}/admin", params: { sort: 'last_name' }

      assert_select "form.b270-admin-reader-sort[action='#{mount}/admin'][method='get']" do
        assert_select 'select[name="sort"]' do
          assert_select 'option', count: 7
          assert_select 'option[value="first_name"]', text: 'First Name'
          assert_select 'option[value="last_name"][selected="selected"]', text: 'Last Name'
          assert_select 'option[value="most_completed"]', text: 'Most days completed'
          assert_select 'option[value="least_completed"]', text: 'Least days completed'
          assert_select 'option[value="most_recent_activity"]', text: 'Most recent activity'
          assert_select 'option[value="least_recent_activity"]', text: 'Least recent activity'
          assert_select 'option[value="consistency"]', text: 'Consistency ranking'
        end
        assert_select 'input[type="submit"][value="Sort"]'
      end
    end

    def test_reader_stats_are_available_in_a_dismissable_dialog
      @reader.mark_through!(3)
      sign_in_as_admin

      get "#{mount}/admin", params: { sort: 'least_completed' }

      assert_select 'button[data-b270-reader-stats-open][hidden][aria-haspopup="dialog"]' \
                    '[aria-controls="b270-reader-stats-dialog"]', text: 'Reader Stats'
      assert_select 'dialog#b270-reader-stats-dialog[data-b270-reader-stats-dialog]' \
                    '[aria-labelledby="b270-reader-stats-title"]:not([open])' do
        assert_select 'h2#b270-reader-stats-title', text: 'Reader Stats'
        assert_select 'form[method="dialog"] button[type="submit"]', text: 'Close'
      end
      expected = Bible270::ReaderProgressReport.new(sort: 'least_completed').to_table
      stats = css_select('#b270-reader-stats-dialog pre').first.text
      assert_equal expected, stats
      assert_includes stats, 'Last Activity'
      last_activity = Bible270.local_time(@reader.checkoffs.maximum(:created_at)).strftime('%b %-d, %Y')
      assert_includes stats, last_activity
      assert_match(%r{Bible270ReaderStats.*showModal.*target\.close.*turbo:load}m, response.body)
    end

    def test_the_reader_list_can_be_ordered_by_last_name
      Bible270::Reader.create!(provider: 'email', uid: 'z@example.org', email: 'z@example.org',
                               display_name: 'Aaron Zebedee', first_name: 'Aaron', last_name: 'Zebedee')
      Bible270::Reader.create!(provider: 'email', uid: 'y@example.org', email: 'y@example.org',
                               display_name: 'Zeke Aaronson', first_name: 'Zeke', last_name: 'Aaronson')
      sign_in_as_admin

      get "#{mount}/admin", params: { sort: 'last_name' }

      assert_operator response.body.index('Zeke Aaronson'), :<, response.body.index('Aaron Zebedee')
    end

    def test_the_reader_list_can_be_ordered_by_completed_days
      most = Bible270::Reader.create!(provider: 'email', uid: 'most@example.org', email: 'most@example.org',
                                      display_name: 'Most Reader')
      least = Bible270::Reader.create!(provider: 'email', uid: 'least@example.org', email: 'least@example.org',
                                       display_name: 'Least Reader')
      most.mark_through!(5)
      least.mark_through!(2)
      sign_in_as_admin

      get "#{mount}/admin", params: { sort: 'most_completed' }
      assert_operator response.body.index(most.display_name), :<, response.body.index(least.display_name)
      assert_select 'option[value="most_completed"][selected="selected"]'

      get "#{mount}/admin", params: { sort: 'least_completed' }
      assert_operator response.body.index(least.display_name), :<, response.body.index(most.display_name)
      assert_select 'option[value="least_completed"][selected="selected"]'
    end

    def test_the_reader_list_and_stats_can_be_ordered_by_recent_activity
      oldest = Bible270::Reader.create!(provider: 'email', uid: 'oldest@example.org', email: 'oldest@example.org',
                                        display_name: 'Oldest Activity')
      newest = Bible270::Reader.create!(provider: 'email', uid: 'newest@example.org', email: 'newest@example.org',
                                        display_name: 'Newest Activity')
      no_activity = Bible270::Reader.create!(provider: 'email', uid: 'none@example.org', email: 'none@example.org',
                                             display_name: 'No Activity')
      oldest_checkoff = oldest.checkoffs.create!(day: 1, track: 'ot', part: 0)
      newest_checkoff = newest.checkoffs.create!(day: 1, track: 'ot', part: 0)
      oldest_checkoff.update_column(:created_at, Time.utc(2026, 9, 1, 12))
      newest_checkoff.update_column(:created_at, Time.utc(2026, 9, 2, 12))
      sign_in_as_admin

      get "#{mount}/admin", params: { sort: 'most_recent_activity' }

      assert_reader_order(newest, oldest, no_activity)
      assert_reader_stats_order(newest, oldest, no_activity)
      assert_select 'option[value="most_recent_activity"][selected="selected"]'

      get "#{mount}/admin", params: { sort: 'least_recent_activity' }

      assert_reader_order(oldest, newest, no_activity)
      assert_reader_stats_order(oldest, newest, no_activity)
      assert_select 'option[value="least_recent_activity"][selected="selected"]'
    end

    def test_an_unknown_reader_sort_falls_back_to_first_name
      first = Bible270::Reader.create!(provider: 'email', uid: 'a@example.org', email: 'a@example.org',
                                       display_name: 'Aaron Zebedee')
      last = Bible270::Reader.create!(provider: 'email', uid: 'z@example.org', email: 'z@example.org',
                                      display_name: 'Zeke Aaronson')
      sign_in_as_admin

      get "#{mount}/admin", params: { sort: 'not-a-sort' }

      assert_operator response.body.index(first.display_name), :<, response.body.index(last.display_name)
      assert_select 'option[value="first_name"][selected="selected"]'
    end
  end
end
