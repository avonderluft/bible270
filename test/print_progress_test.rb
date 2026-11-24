# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class PrintProgressTest < ActionDispatch::IntegrationTest
    def setup
      clear_engine_tables!
      keys = %i[start_date allow_reader_start_date require_sign_in_to_participate chapter_breaks chapter_breaks_path]
      @previous_config = keys.to_h do |key|
        [key, Bible270.config.public_send(key)]
      end
      Bible270.config.start_date = nil
      Bible270.config.allow_reader_start_date = true
      @reader = create_reader('Pat')
    end

    def teardown
      @previous_config.each { |key, value| Bible270.config.public_send("#{key}=", value) }
    end

    def test_visitors_cannot_print_even_when_sign_in_to_participate_is_optional
      Bible270.config.require_sign_in_to_participate = false
      get progress_path
      assert_select "a[href='#{print_path}']", count: 0

      get print_path, params: { reader_id: @reader.id }
      assert_redirected_to "#{mount}/sign_in?origin=#{CGI.escape(print_path)}"
      assert_select 'table', count: 0
    end

    def test_my_progress_links_to_a_full_page_print_view
      sign_in
      get progress_path
      assert_select '.b270-progress-heading > h1', text: 'Your reading journey'
      assert_select ".b270-progress-heading > h1 + a[href='#{print_path}'][data-turbo='false']", text: 'Print checklist'

      env = Rails.application.env_config.merge('action_dispatch.content_security_policy_nonce_generator' => ->(_request) { 'print-nonce' })
      Rails.application.stub(:env_config, env) { get print_path }
      assert_response :success
      assert_select 'style[nonce="print-nonce"], script[nonce="print-nonce"]', count: 2
      assert_select 'header.checklist-heading > h1#checklist-title', text: 'Reading checklist'
      assert_select 'header.checklist-heading > h1 + p', text: '270-day plan for Pat Reader'
      refute_includes response.body, 'Ticked boxes show saved check-offs. Mark the empty boxes as you read.'
      assert_select 'button[type="button"]', text: 'Print checklist'
      assert_select '.print-controls p', text: %r{Ctrl\+P}
      assert_select 'html[data-b270-display-mode], body.b270, nav, footer, link, img, iframe, script[src], [onclick]', count: 0
      assert_select 'ol.compact-checklist[aria-labelledby="checklist-title"]', count: 1
      assert_select 'table.screen-checklist[aria-labelledby="checklist-title"] thead th[scope="col"]' do |headers|
        assert_equal ['Day', 'Old Testament', 'New Testament', 'Psalms & Proverbs'], headers.map(&:text)
      end
    end

    def test_base_print_includes_all_days_and_only_the_signed_in_readers_saved_parts
      other = create_reader('Eli')
      other.checkoffs.create!(day: 1, track: 'ot', part: 0)
      @reader.checkoffs.create!(day: 1, track: 'ot', part: 1)
      sign_in

      get print_path, params: { reader_id: other.id, id: other.id }
      assert_days(270)
      assert_equal 'private, no-store', response.headers['Cache-Control']

      row = css_select(day_row(1)).first
      assert_equal ['Genesis 1', 'Genesis 2', 'Genesis 3', 'Matthew 1', 'Psalm 1'], row.css('.reference').map(&:text)
      assert_equal ['', '✓', '', '', ''], row.css('.box[aria-hidden="true"]').map(&:text)
      statuses = row.css('.passage .visually-hidden').map { |text| text.text.delete_prefix(' — ') }
      assert_equal ['Not yet read', 'Read', 'Not yet read', 'Not yet read', 'Not yet read'], statuses
      assert_select "#{day_row(26)} .reference", text: 'Matthew 26:1–35'
      assert_select "#{day_row(270)} .reference", text: 'Revelation 22'
      assert_equal ['Gen 1', '2', '3', 'Mat 1', 'Psa 1'], compact_references(1)
      assert_equal ['Zec 14', 'Mal 1', '2', '3', '4', 'Rev 22', 'Psa 1'], compact_references(270)
      assert_includes compact_references(26), 'Mat 26:1–35'
      assert_compact_matches_screen
    end

    def test_custom_base_plan_keeps_dates_and_checkoffs_with_a_long_reader_name
      Bible270.config.chapter_breaks_path = nil
      Bible270.config.chapter_breaks = { 'Psalm 119' => [9, 71, 150], 'Matthew 26' => [11, 18, 54], 'Luke 1' => [] }
      name = 'Alexandria Beatrice Catherine Dominique Elizabeth Francesca Genevieve Henrietta Isabella Josephine Kensington Lancaster'
      start = Date.new(2025, 1, 15)
      @reader.update!(display_name: name)
      @reader.set_start_date!(start)
      @reader.checkoffs.create!(day: 26, track: 'nt', part: 0)
      sign_in

      get print_path
      assert_days(270)
      assert_select 'header.checklist-heading > h1 + p', text: "270-day plan for #{name} · Day 1: Jan 15, 2025"
      assert_select ".print-only time[datetime='#{start.iso8601}']", text: 'Jan 15, 2025'
      assert_select "#{day_row(270)} time[datetime='#{(start + 269).iso8601}']"
      assert_select "#{day_row(26)} .track-nt .reference", text: 'Matthew 26:1–11'
      assert_select "#{day_row(26)} .track-nt .box", text: '✓'
      assert_includes compact_references(26), 'Mat 26:1–11'
      assert_includes compact_references(216), 'Psa 119:72–150'
      assert_compact_matches_screen
    end

    def test_270_override_hides_saved_extension_checkoffs_without_removing_them
      Bible270::PlanRun.current.update!(plus95_enabled: true)
      @reader.reload.checkoffs.create!(day: 273, track: 'pp', part: 1)
      sign_in
      get print_path
      assert_days(365)
      assert_extension_checkoff

      @reader.participation.update!(plus95_override: false)
      assert_no_difference('Bible270::Checkoff.count') do
        get print_path
      end
      assert_days(270)
      assert_select '.box', text: '✓', count: 0
    end

    def test_archived_print_uses_the_frozen_calendar_and_length_override
      start = Date.new(2025, 1, 15)
      @reader.set_start_date!(start)
      @reader.participation.update!(plus95_override: true)
      @reader.checkoffs.create!(day: 273, track: 'pp', part: 1)
      run = Bible270::PlanRun.current
      Bible270::PlanRun.restart!(start_date: start + 365, expected_run_id: run.id, plus95_enabled: false)
      sign_in

      get print_path
      assert_days(365)
      assert_select 'thead th[scope="col"]', text: 'Date'
      assert_select 'header.checklist-heading > h1 + p', text: '365-day plan for Pat Reader · Day 1: Jan 15, 2025'
      assert_select "#{day_row(1)} time[datetime='#{start.iso8601}']", text: 'Jan 15, 2025'
      assert_select "#{day_row(365)} time[datetime='#{(start + 364).iso8601}']"
      assert_select ".print-only time[datetime='#{start.iso8601}']", text: 'Jan 15, 2025'
      assert_extension_checkoff
      assert_equal ['Mat 8', '9', 'Psa 5', 'Pro 1'], compact_references(273)
      assert_compact_matches_screen
    end

    def test_print_reads_checkoffs_in_bulk
      Bible270::PlanRun.current.update!(plus95_enabled: true)
      @reader.reload.checkoffs.create!(day: 365, track: 'nt', part: 0)
      sign_in
      queries = []
      record_selects = ->(*_, payload) do
        sql = payload[:sql]
        queries << sql if sql.match?(%r{\ASELECT\b}i) && sql.include?('bible270_')
      end
      ActiveSupport::Notifications.subscribed(record_selects, 'sql.active_record') { get print_path }

      assert_days(365)
      assert_select "#{day_row(365)} .box", text: '✓', count: 1
      assert_equal(1, queries.count { |sql| sql.include?('bible270_checkoffs') })
      assert_operator queries.size, :<=, 6, 'the whole checklist should use a bounded number of queries'
    end

  private

    def mount = Bible270.config.mount_at.chomp('/')
    def progress_path = "#{mount}/progress"
    def print_path = "#{progress_path}/print"
    def day_row(day) = "tbody #day-#{day}"

    def create_reader(name)
      email = "#{name.downcase}@example.org"
      Bible270::Reader.create!(provider: 'email', uid: email, email: email, display_name: "#{name} Reader")
    end

    def sign_in
      _record, raw = Bible270::SignInToken.issue!(@reader.email)
      get "#{mount}/sign_in/email/#{raw}"
    end

    def assert_days(days)
      assert_response :success
      extended = days > Bible270::Plan::DAYS
      assert_select 'main.checklist-base', count: extended ? 0 : 1
      assert_select 'main.checklist-extended', count: extended ? 1 : 0
      assert_equal (1..days).map(&:to_s), css_select('tbody th[scope="row"]').map(&:text)
      assert_equal (1..days).map { |day| "Day #{day}" }, css_select('.compact-checklist .day-number').map(&:text)
    end

    def compact_references(day)
      css_select('.compact-day')[day - 1].css('.short-reference').map(&:text)
    end

    def assert_compact_matches_screen
      rows = css_select('.screen-checklist tbody tr').zip(css_select('.compact-day'))
      rows.each_with_index do |(screen, row), index|
        assert_equal screen.css('.box').map(&:text), row.css('.box[aria-hidden="true"]').map(&:text), "boxes on day #{index + 1}"
        labels = screen.css('.passage').map { |passage| passage.at_css('.reference').text + passage.at_css('.visually-hidden').text }
        assert_equal labels, row.css('.passage[role="img"]').map { |passage| passage['aria-label'] }, "accessible labels on day #{index + 1}"
      end
    end

    def assert_extension_checkoff
      row = css_select(day_row(273)).first
      assert_select 'table[aria-labelledby="extension-title"] .track-ot', count: 0
      assert_equal ['Matthew 8', 'Matthew 9'], row.css('td.track-nt .reference').map(&:text)
      assert_equal ['Psalm 5', 'Proverbs 1'], row.css('td.track-pp .reference').map(&:text)
      assert_equal ['', '✓'], row.css('td.track-pp .box').map(&:text)
    end
  end
end
