# frozen_string_literal: true

require_relative 'support/admin_runs_test_case'

if RAILS_LOADED
  class AdminReaderListsTest < Bible270AdminRunsTestCase
    def test_active_readers_use_an_expanded_native_disclosure_without_hiding_tools_or_stats
      @reader.archive!
      get admin_path, params: { sort: 'consistency' }

      assert_response :success
      assert_select 'details#b270-active-readers.b270-index[open]', count: 1 do
        assert_select '> summary .b270-active-readers-show', text: 'Show Active Readers (2)'
        assert_select '> summary .b270-active-readers-hide', text: 'Hide Active Readers (2)'
        assert_select '> .b270-list .b270-li', count: 2
        assert_select "a[aria-label='#{@admin.display_name}']", count: 1
        assert_select "a[aria-label='#{@reader.display_name}']", count: 0
        assert_select 'form, .b270-admin-reader-tools, dialog, script', count: 0
      end
      assert_select '.b270-admin-reader-tools select[name="sort"] option[value="consistency"][selected]'
      assert_select '.b270-admin-reader-tools [data-b270-reader-stats-open][aria-controls="b270-reader-stats-dialog"]', text: 'Reader Stats'
      assert_select '.b270-consistency-explanation + details#b270-active-readers'
      assert_select '#b270-active-readers + dialog#b270-reader-stats-dialog pre' do |tables|
        assert_includes tables.first.text, @admin.display_name
        refute_includes tables.first.text, @reader.display_name
      end
      key = css_select('#b270-active-readers').first['data-b270-active-readers-key']
      assert_match(%r{\A#{Regexp.escape(admin_path)}:[a-f0-9]{32}\z}, key)
      assert_select 'script[data-b270-admin-reader-list]', count: 1
      get admin_path, params: { sort: 'last_name' }
      assert_equal key, css_select('#b270-active-readers').first['data-b270-active-readers-key']
      assert_match(%r{details\.b270-active-readers>summary\{margin:0 0 12px\}}, response.body)
      assert_match(%r{details\.b270-alumni\{margin-bottom:24px\}}, response.body)
    end

    def test_empty_active_disclosure_remains_expanded_when_there_are_only_alumni
      [@site_admin, @admin, @reader].each(&:archive!)
      get admin_path

      assert_response :success
      assert_select 'details#b270-active-readers[open]' do
        assert_select 'summary .b270-active-readers-hide', text: 'Hide Active Readers (0)'
        assert_select '.b270-li', count: 0
        assert_select '.b270-hint', text: 'No active readers yet.'
      end
      assert_select '.b270-admin-reader-tools', count: 1
      assert_select '#b270-alumni .b270-li', count: 3
    end

    def test_alumni_use_a_collapsed_native_disclosure_with_the_list_ready_to_expand
      @reader.archive!
      get admin_path

      assert_response :success
      assert_select 'details#b270-alumni.b270-index:not([open])' do
        assert_select 'summary .b270-alumni-show', text: 'Show Alumni (1)'
        assert_select 'summary .b270-alumni-hide', text: 'Hide Alumni (1)'
        assert_select ".b270-li a[aria-label='#{@reader.display_name}']", count: 1
        assert_select '.stat button.b270-admin-activate', text: 'Make Active', count: 1
      end
      assert_select 'input[name="show_alumni"]', count: 0
      get admin_path, params: { show_alumni: '1' }
      assert_select 'details#b270-alumni:not([open])'
    end

    def test_role_and_alumni_badges_share_compact_styling_in_both_lists
      get admin_path

      assert_select '.b270-reader-theme .b270-admin-reader-details .name > .b270-badge.b270-reader-badge.b270-role-badge', text: 'Site-admin', count: 1
      assert_select '.b270-reader-theme .b270-admin-reader-details .name > .b270-badge.b270-reader-badge.b270-role-badge', text: 'Admin', count: 1
      assert_select '.b270-role-badge > span', text: 'Site-admin', count: 1
      assert_select '.b270-role-badge > span', text: 'Admin', count: 1
      @site_admin.archive!
      @admin.archive!
      @reader.archive!
      get admin_path

      assert_select '#b270-alumni .name > .b270-reader-badge.b270-role-badge', text: 'Site-admin', count: 1
      assert_select '#b270-alumni .name > .b270-reader-badge.b270-role-badge', text: 'Admin', count: 1
      assert_select '#b270-alumni .name > .b270-reader-badge:not(.b270-role-badge) > span', text: 'Alumni', count: 3
    end

    def test_empty_alumni_disclosure_still_has_an_informative_toggle
      get admin_path

      assert_select 'details#b270-alumni:not([open])' do
        assert_select 'summary .b270-alumni-show', text: 'Show Alumni (0)'
        assert_select '.b270-hint', text: 'No alumni yet.'
      end
    end

    def test_alumni_share_every_sort_and_layout_but_have_separate_report_data
      @reader.mark_through!(2)
      @reader.archive!
      other = create_reader('Zoe Alumni')
      other.mark_through!(4)
      other.archive!

      Bible270::AdminController::READER_SORT_OPTIONS.each_key do |sort|
        get admin_path, params: { sort: sort }

        assert_response :success
        assert_select '.b270-admin-reader-sort select[name="sort"] option[selected]' do |options|
          assert_equal sort, options.first['value']
        end
        assert_select 'details#b270-active-readers[open] .b270-li', count: 2
        assert_select 'details#b270-alumni:not([open])'
        assert_select '#b270-alumni .b270-li', count: 2
        assert_select '#b270-alumni .b270-reader-consistency', count: 2
        assert_select '#b270-alumni .b270-reader-activity', count: 2
        assert_select '#b270-alumni .b270-badge', text: 'Alumni', count: 2
        assert_select '.b270-consistency-explanation', count: sort == 'consistency' ? 1 : 0
        assert_select '#b270-reader-stats-dialog pre' do |tables|
          refute_includes tables.first.text, @reader.display_name
          refute_includes tables.first.text, other.display_name
          assert_includes tables.first.text, @admin.display_name
        end
        assert_select "#b270-alumni a[href='mailto:#{@reader.email}']" do |emails|
          assert_includes emails.first.parent.text.squish, '2/270 days · 8 days behind'
        end
        next unless %w[most_completed least_completed].include?(sort)

        names = css_select('#b270-alumni .name a').map(&:text)
        expected = sort == 'most_completed' ? [other.display_name, @reader.display_name] : [@reader.display_name, other.display_name]
        assert_equal expected, names
      end
      get admin_path, params: { sort: 'most_completed' }
      assert_select '.b270-admin-reader-sort input[name="show_alumni"]', count: 0
      assert_select 'details#b270-alumni:not([open])'
      assert_select '#b270-alumni .b270-li', count: 2
    end

    def test_active_counts_shared_calendars_and_everyone_broadcast_exclude_alumni
      @reader.update!(started_on: Bible270.today - 1)
      @reader.archive!
      alumni_admin = create_reader('Alumni Admin', admin: true)
      alumni_admin.archive!
      get admin_path

      assert_select '.lede', text: %r{2 readers taking part}
      assert_includes response.body, '2 readers following the shared calendar'
      assert_includes response.body, '2 active readers'
      assert_includes response.body, '3 admins'
      assert_includes response.body, 'including alumni admins'
      assert_includes response.body, 'Ordinary alumni do not receive broadcasts'
      deliveries = []
      Bible270::NoticeMailer.stub(:broadcast, ->(**arguments) {
        deliveries << arguments.fetch(:reader_id)
        Object.new.tap { |mail| mail.define_singleton_method(:deliver_now) { true } }
      }) do
        post "#{mount}/admin/broadcast", params: { subject: 'Hello', body: 'Welcome', audience: 'everyone' }
        assert_equal [@site_admin.id, @admin.id].sort, deliveries.sort
        deliveries.clear
        post "#{mount}/admin/broadcast", params: { subject: 'Hello admins', body: 'Welcome', audience: 'admins' }
        assert_equal [@site_admin.id, @admin.id, alumni_admin.id].sort, deliveries.sort
      end
    end
  end
end
