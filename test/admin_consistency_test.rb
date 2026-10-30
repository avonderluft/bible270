# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class AdminConsistencyTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_config = %i[
        admin_emails admin_resolver registration_notice_deliver_later start_date allow_reader_start_date time_zone
      ].to_h { |key| [key, Bible270.config.public_send(key)] }
      @start = Date.new(2026, 1, 1)
      @today = @start + 7
      @sequence = 0
      Bible270.config.admin_resolver = nil
      Bible270.config.registration_notice_deliver_later = false
      Bible270.config.start_date = @start
      Bible270.config.allow_reader_start_date = true
      Bible270.config.time_zone = 'UTC'
      @admin = create_reader('The Boss')
      Bible270.config.admin_emails = [@admin.email]
    end

    def teardown
      @previous_config&.each { |key, value| Bible270.config.public_send("#{key}=", value) }
      Bible270::Setting.open_enrollment!
      Bible270::Setting.clear_run_start_date!
    end

    def test_selected_consistency_ranks_history_instead_of_current_completed_counts
      steady = create_reader('Zoe Steady')
      catchup = create_reader('Aaron Catchup')
      complete_daily(steady, 7)
      (1..8).each { |day| complete(catchup, day, on: @today - 1) }
      sign_in_as(@admin)

      get_admin(sort: 'most_completed')
      assert_reader_and_stats_order(catchup, steady, @admin)
      assert_equal 7, steady.days_completed
      assert_equal 8, catchup.days_completed

      get_admin(sort: 'consistency')

      assert_response :success
      assert_select 'select[name="sort"] option[selected]', count: 1
      assert_select 'option[value="consistency"][selected="selected"]', text: 'Consistency ranking'
      assert_reader_and_stats_order(steady, catchup, @admin)
      assert_select '.b270-reader-consistency', count: 3
      assert_consistency steady, 'Consistency: 100.0 · On track/ahead: 100% · 7 days evaluated'
      assert_consistency catchup, 'Consistency: 70.7 · On track/ahead: 14% · 7 days evaluated'
      assert_consistency @admin, 'Consistency: 60.0 · On track/ahead: 0% · 7 days evaluated'
      assert_equal ['Rank', 'Name', 'Days Read', 'Status', 'Last Activity'], stats_table.lines.first.strip.split(%r{ {2,}})
      assert_equal %w[1 2 3], stats_table.lines.drop(2).map(&:split).map(&:first)
      refute_includes stats_table, 'Consistency'
      refute_includes stats_table, 'On track/ahead'
    end

    def test_tied_readers_share_competition_ranks_and_names_only_order_the_ties
      tied = ['Zoe Steady', 'Aaron Steady', 'Mia Steady'].map { |name| create_reader(name) }
      tied.each { |reader| complete_daily(reader, 7) }
      almost = create_reader('Dana Almost')
      complete_daily(almost, 6)
      catchup = create_reader('Eli Catchup')
      (1..7).each { |day| complete(catchup, day, on: @today - 1) }
      sign_in_as(@admin)

      get_admin(sort: 'consistency')

      assert_reader_and_stats_order(tied[1], tied[2], tied[0], almost, catchup, @admin)
      assert_equal %w[1 1 1 4 5 6], stats_table.lines.drop(2).map(&:split).map(&:first)
    end

    def test_repeated_ties_include_provisional_readers_but_not_unranked_readers
      Bible270.config.start_date = nil
      @admin.update!(started_on: @start)
      established = create_reader('Other Established', start_date: @start)
      provisional = ['Alpha New', 'Bravo New'].map { |name| create_reader(name, start_date: @today - 2) }
      unranked = create_reader('Undated Reader')
      sign_in_as(@admin)

      get_admin(sort: 'consistency')

      assert_reader_and_stats_order(established, @admin, *provisional, unranked)
      assert_equal ['1', '1', '3', '3', '—'], stats_table.lines.drop(2).map(&:split).map(&:first)
    end

    def test_equal_rounded_scores_do_not_create_false_ties
      other = create_reader('Other Reader')
      results = {
        @admin.id => Bible270::ReaderConsistency::Result.new(score: Rational(10_001, 100), on_track_percentage: 100, days_evaluated: 7),
        other.id => Bible270::ReaderConsistency::Result.new(score: Rational(10_002, 100), on_track_percentage: 100, days_evaluated: 7)
      }
      report = Bible270::ReaderProgressReport.new(readers: [@admin, other], completed_days: {}, recent_activities: {}, sort: 'consistency')

      report.stub(:consistency_for, ->(reader) { results.fetch(reader.id) }) do
        assert_equal [other, @admin], report.sorted_readers
        assert_equal %w[1 2], report.to_table.lines.drop(2).map(&:split).map(&:first)
      end
    end

    def test_established_readers_precede_higher_scoring_provisional_readers_and_unranked_readers_are_last
      Bible270.config.start_date = nil
      @admin.update!(started_on: @start)
      six_evenings = create_reader('Zoe Six', start_date: @today - 6)
      one_evening = create_reader('Aaron One', start_date: @today - 1)
      [six_evenings, one_evening].each do |reader|
        (1..20).each { |day| complete(reader, day, on: reader.started_on) }
      end
      undated = create_reader('Alpha Undated')
      starts_today = create_reader('Bravo Today', start_date: @today)
      future = create_reader('Charlie Future', start_date: @today + 1)
      just_joined = create_reader('Delta New', start_date: @start, created_at: timestamp(@today))
      sign_in_as(@admin)

      get_admin(sort: 'consistency')

      assert_response :success
      assert_reader_and_stats_order(@admin, six_evenings, one_evening, undated, starts_today, future, just_joined)
      assert_consistency @admin, 'Consistency: 60.0 · On track/ahead: 0% · 7 days evaluated'
      assert_consistency six_evenings, 'Provisional · Consistency: 135.0 · On track/ahead: 100% · 6 days evaluated'
      assert_consistency one_evening, 'Provisional · Consistency: 135.0 · On track/ahead: 100% · 1 day evaluated'
      assert_equal ['1', '2', '3', '—', '—', '—', '—'], stats_table.lines.drop(2).map(&:split).map(&:first)
      [undated, starts_today, future, just_joined].each do |reader|
        assert_consistency reader, 'Consistency: Not ranked'
      end
    end

    def test_reconstructed_history_explanation_and_metrics_follow_surviving_checkoffs_and_current_schedule
      reader = create_reader('Steady Reader')
      complete_daily(reader, 7)
      sign_in_as(@admin)

      get_admin(sort: 'consistency')

      explanation = css_select('p.b270-hint').map { |node| node.text.squish }.find do |text|
        text.include?('Average daily score')
      end
      refute_nil explanation
      assert_includes explanation, 'Average daily score through yesterday'
      assert_includes explanation, '100 on track, +5 per day ahead (max +35), −10 per day behind'
      assert_includes explanation, 'Under 7 days is provisional; no history is unranked'
      assert_includes explanation, 'Check-off or schedule changes can alter scores'
      assert_operator explanation.split.length, :<=, 45
      assert_consistency reader, 'Consistency: 100.0 · On track/ahead: 100% · 7 days evaluated'

      reader.checkoffs.where(day: 1).first.destroy!
      get_admin(sort: 'consistency')
      assert_consistency reader, 'Consistency: 90.0 · On track/ahead: 0% · 7 days evaluated'

      reader.set_start_date!(@start + 1)
      get_admin(sort: 'consistency')
      assert_consistency reader, 'Provisional · Consistency: 100.0 · On track/ahead: 100% · 6 days evaluated'
    end

    def test_every_sort_displays_consistency_including_provisional_and_unranked_readers
      reader = create_reader('Ordinary Reader')
      complete_daily(reader, 7)
      provisional = create_reader('Provisional Reader', start_date: @today - 2)
      unranked = create_reader('New Reader', start_date: @today)
      sign_in_as(@admin)

      [nil, *Bible270::AdminController::READER_SORT_OPTIONS.keys, 'unknown'].each do |sort|
        get_admin(sort: sort)

        assert_response :success
        assert_select '.b270-reader-consistency', count: 4
        assert_consistency reader, 'Consistency: 100.0 · On track/ahead: 100% · 7 days evaluated'
        assert_consistency @admin, 'Consistency: 60.0 · On track/ahead: 0% · 7 days evaluated'
        assert_consistency provisional, 'Provisional · Consistency: 85.0 · On track/ahead: 0% · 2 days evaluated'
        assert_consistency unranked, 'Consistency: Not ranked'
        assert_includes response.body, 'Average daily score'
        headers = ['Name', 'Days Read', 'Status', 'Last Activity']
        headers.unshift('Rank') if sort == 'consistency'
        assert_equal headers, stats_table.lines.first.strip.split(%r{ {2,}})
        selected = Bible270::AdminController::READER_SORT_OPTIONS.key?(sort) ? sort : 'first_name'
        assert_select "option[value='#{selected}'][selected]", count: 1
      end
    end

    def test_negative_scores_display_as_zero_for_every_sort_without_changing_rank_order
      @today = @start + 21
      behind = create_reader('Aaron Behind', start_date: @start - 5)
      sign_in_as(@admin)
      results = Bible270::ReaderConsistency.new(readers: [@admin, behind], today: @today)
      assert_operator results.for(@admin).score, :<, 0
      assert_operator results.for(behind).score, :<, results.for(@admin).score

      [nil, *Bible270::AdminController::READER_SORT_OPTIONS.keys, 'unknown'].each do |sort|
        get_admin(sort: sort)

        assert_response :success
        assert_consistency @admin, 'Consistency: 0 · On track/ahead: 0% · 21 days evaluated'
        assert_consistency behind, 'Consistency: 0 · On track/ahead: 0% · 22 days evaluated'
        next unless sort == 'consistency'

        assert_reader_and_stats_order(@admin, behind)
        assert_equal %w[1 2], stats_table.lines.drop(2).map(&:split).map(&:first)
      end
    end

    def test_visitors_cannot_access_consistency_rankings_or_trigger_history_calculation
      without_consistency_calculation do
        get_admin(sort: 'consistency')

        assert_response :not_found
        assert_select '.b270-reader-consistency', count: 0
      end
    end

    def test_nonadmins_cannot_access_consistency_rankings_or_trigger_history_calculation
      sign_in_as(create_reader('Ordinary Reader'))

      without_consistency_calculation do
        get_admin(sort: 'consistency')

        assert_response :not_found
        assert_select '.b270-reader-consistency', count: 0
      end
    end

    def test_each_report_calculates_history_once_in_two_bulk_queries_and_reuses_it_for_sort_labels_and_table
      complete_daily(create_reader('Steady Reader'), 7)
      sign_in_as(@admin)
      original_report = Bible270::ReaderProgressReport.method(:new)
      original_calculator = Bible270::ReaderConsistency.method(:new)
      reports = []
      calculations = []
      build_report = ->(**options) { original_report.call(**options).tap { |report| reports << report } }
      build_calculator = ->(**options) do
        calculator = nil
        queries = capture_selects { calculator = original_calculator.call(**options) }
        calculations << { reader_ids: options.fetch(:readers).map(&:id).sort, queries: queries }
        calculator
      end

      Bible270::ReaderProgressReport.stub(:new, build_report) do
        Bible270::ReaderConsistency.stub(:new, build_calculator) do
          2.times do |index|
            if index.positive?
              5.times { |number| complete(create_reader("Extra Reader #{number}"), 1, on: @start) }
            end
            normal_queries = capture_selects { get_admin(sort: 'first_name') }
            assert_equal (index * 2) + 1, calculations.length
            queries = capture_selects { get_admin(sort: 'consistency') }

            assert_response :success
            assert_equal (index + 1) * 2, calculations.length
            calculation = calculations.last
            assert_equal Bible270::Reader.order(:id).pluck(:id), calculation[:reader_ids]
            history_queries = checkoff_queries(calculation[:queries])
            assert_equal 2, history_queries.length
            assert_match(%r{COUNT\(}i, history_queries.first[:sql])
            assert_match(%r{MAX\(.*created_at}i, history_queries.last[:sql])
            history_queries.each do |query|
              assert_match(%r{GROUP BY.*reader_id.*day}i, query[:sql])
              ids = query[:binds].select { |bind| bind.name == 'reader_id' }.map(&:value_for_database)
              assert_equal calculation[:reader_ids], ids.sort
            end
            assert_equal 2, checkoff_queries(calculations[-2][:queries]).length
            assert_equal calculation[:reader_ids], calculations[-2][:reader_ids]
            assert_equal checkoff_queries(normal_queries).length, checkoff_queries(queries).length

            report = reports.last
            reuse_queries = capture_selects do
              sorted = report.sorted_readers
              rows = report.rows
              2.times do
                assert_same sorted, report.sorted_readers
                assert_same rows, report.rows
                sorted.each { |reader| assert_same report.consistency_for(reader), report.consistency_for(reader) }
                assert_equal stats_table, report.to_table
              end
            end
            assert_empty reuse_queries
            assert_equal (index + 1) * 2, calculations.length
          end
        end
      end
      refute_same reports[1], reports[3]
    end

    def test_empty_consistency_report_needs_no_history_and_includes_the_rank_column
      without_consistency_calculation do
        queries = capture_selects do
          report = Bible270::ReaderProgressReport.new(
            readers: [], completed_days: {}, recent_activities: {}, sort: 'consistency'
          )
          assert_empty report.sorted_readers
          assert_empty report.rows
          assert_empty report.sorted_readers
          assert_predicate report, :empty?
          assert_equal ['Rank', 'Name', 'Days Read', 'Status', 'Last Activity'], report.to_table.lines.first.strip.split(%r{ {2,}})
          assert_equal 2, report.to_table.lines.length
        end
        assert_empty queries
      end
    end

  private

    def mount = Bible270.config.mount_at.chomp('/')

    def sign_in_as(reader)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      Bible270.stub(:today, @today) { get "#{mount}/sign_in/email/#{raw}" }
      assert_response :redirect
    end

    def get_admin(sort:)
      Bible270.stub(:today, @today) do
        get "#{mount}/admin", params: sort ? { sort: sort } : {}
      end
    end

    def create_reader(name, start_date: nil, created_at: timestamp(@start - 1))
      @sequence += 1
      email = "admin-consistency#{@sequence}@example.org"
      Bible270::Reader.create!(provider: 'email', uid: email, email: email, display_name: name,
                               started_on: start_date, created_at: created_at)
    end

    def timestamp(date)
      Time.utc(date.year, date.month, date.day, 12)
    end

    def complete(reader, day, on:)
      reader.mark_day_complete!(day)
      reader.checkoffs.where(day: day).update_all(created_at: timestamp(on))
    end

    def complete_daily(reader, days)
      (1..days).each { |day| complete(reader, day, on: @start + day - 1) }
    end

    def stats_table
      css_select('#b270-reader-stats-dialog pre').first.text
    end

    def assert_reader_and_stats_order(*readers)
      assert_equal readers.map(&:display_name), css_select('.b270-list .name a').map(&:text)
      name_column = stats_table.lines.first.strip.split(%r{ {2,}}).index('Name')
      names = stats_table.lines.drop(2).map { |line| line.strip.split(%r{ {2,}})[name_column] }
      assert_equal readers.map(&:display_name), names
    end

    def assert_consistency(reader, text)
      row = css_select('.b270-list .b270-li').find do |node|
        node.at_css(".name a[href='#{mount}/admin/readers/#{reader.id}']")
      end
      refute_nil row
      label = row.at_css('.b270-reader-consistency')
      refute_nil label
      assert_equal text, label.text.squish
    end

    def without_consistency_calculation(&)
      unexpected = ->(**) { flunk 'ReaderConsistency must not be constructed for this request' }
      Bible270::ReaderConsistency.stub(:new, unexpected, &)
    end

    def checkoff_queries(queries)
      queries.select { |query| query[:sql].include?('bible270_checkoffs') }
    end

    def capture_selects(&block)
      queries = []
      subscriber = ->(_name, _start, _finish, _id, payload) do
        queries << payload if payload[:sql].match?(%r{\ASELECT}i)
      end
      Bible270::Checkoff.uncached do
        ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &block)
      end
      queries
    end
  end
end
