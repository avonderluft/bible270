# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class Plus95ReaderPagesTest < ActionDispatch::IntegrationTest
    BASE_DAYS = Bible270::Plan::DAYS
    EXTENDED_DAYS = Bible270::Plan::EXTENDED_DAYS
    MIXED_DAY = BASE_DAYS + 3
    TURBO = { 'Accept' => 'text/vnd.turbo-stream.html' }.freeze

    def setup
      clear_engine_tables!
      @previous_config = %i[start_date allow_reader_start_date mention_notifications admin_emails].to_h do |key|
        [key, Bible270.config.public_send(key)]
      end
      @start = Bible270.today - (MIXED_DAY - 1)
      Bible270.config.start_date = @start
      Bible270.config.allow_reader_start_date = true
      Bible270.config.mention_notifications = false
      Bible270.config.admin_emails = []
      @reader = create_reader('Pat')
      @run = Bible270::PlanRun.current
    end

    def teardown
      @previous_config.each { |key, value| Bible270.config.public_send("#{key}=", value) }
    end

    def test_visitors_browse_only_the_current_run_and_see_its_calendar
      get mount
      assert_grid_length(BASE_DAYS)
      assert_select '.b270-startline strong', text: formatted_date(@start + BASE_DAYS - 1)
      get day_path(BASE_DAYS + 1)
      assert_redirected_to "#{mount}/"

      update_plus95(true)
      get mount
      assert_grid_length(EXTENDED_DAYS)
      assert_select '.b270-startline strong', text: formatted_date(@start + EXTENDED_DAYS - 1)
      assert_select ".b270-grid a[href='#{day_path(EXTENDED_DAYS)}']" do |cells|
        assert_includes cells.first['aria-label'], formatted_date(@start + EXTENDED_DAYS - 1)
      end

      get day_path(BASE_DAYS)
      assert_select ".b270-daynav a[aria-label='Next day'][href='#{day_path(BASE_DAYS + 1)}']"
      get day_path(EXTENDED_DAYS)
      assert_response :success
      assert_select '.b270-dayhead .date', text: %r{#{formatted_date(@start + EXTENDED_DAYS - 1)}}
      assert_select '.b270-daynav button[aria-label="Next day unavailable"][disabled]'
      get day_path(EXTENDED_DAYS + 1)
      assert_redirected_to "#{mount}/"
    end

    def test_a_signed_in_reader_without_membership_browses_the_current_run
      update_plus95(true)
      @reader.participation.destroy!
      sign_in_as(@reader)
      get day_path(MIXED_DAY)
      assert_grid_length(EXTENDED_DAYS)
      assert_select '.b270-dayhead .date', text: %r{#{formatted_date(@start + MIXED_DAY - 1)}}
      assert_select '.b270-toggle', count: 0
      post "#{day_path(MIXED_DAY)}/comments", params: { comment: { body: 'A reflection without progress' } }
      assert_response :redirect
      assert_equal MIXED_DAY, @reader.comments.last.day
    end

    def test_extension_checkoffs_update_day_progress_track_bars_and_community
      update_plus95(true)
      sign_in_as(@reader)
      Bible270::Plan.present_tracks(MIXED_DAY).each do |track|
        Bible270::Plan.parts_for(MIXED_DAY, track).each_index do |part|
          post "#{day_path(MIXED_DAY)}/toggle/#{track}/#{part}", params: { checked: '1' }, headers: TURBO
          assert_response :success
        end
      end
      assert_select 'turbo-stream[target="day_progress_273"] strong', text: 'Day 273 complete'
      assert_select "turbo-stream[target='day_progress_273'] a[href='#{day_path(MIXED_DAY + 1)}']",
                    text: 'Continue to Day 274 →'

      get "#{mount}/progress"
      assert_select '.b270-bignum .of', text: 'of 365 days complete'
      assert_select '.b270-tracks .val' do |bars|
        assert_equal %w[0/270 1/365 1/365], bars.map(&:text)
      end

      get "#{mount}/community"
      assert_select '.b270-bar[role="progressbar"][aria-valuemax="365"][aria-valuenow="1"]' do |bars|
        assert_equal '1 of 365 days complete; today is day 273', bars.first['aria-valuetext']
      end
      assert_select '.b270-reader-progress-count', text: '1 / 365 days'
      assert_select '.b270-progress-today'

      update_plus95(false)
      assert_no_difference('Bible270::Checkoff.count') do
        post "#{day_path(MIXED_DAY)}/toggle/nt/0", params: { checked: '0' }, headers: TURBO
        assert_response :bad_request
      end
      get "#{mount}/community"
      assert_select '.b270-bar[role="progressbar"][aria-valuemax="270"][aria-valuenow="0"]'
      assert_select '.b270-progress-today', count: 0

      update_plus95(true)
      get "#{mount}/community"
      assert_select '.b270-bar[role="progressbar"][aria-valuemax="365"][aria-valuenow="1"]'
    end

    def test_extension_reflections_use_only_present_tracks_and_link_each_passage
      update_plus95(true)
      sign_in_as(@reader)
      get day_path(MIXED_DAY)
      assert_select "#reading_#{MIXED_DAY}_ot", count: 0
      bible_com_refs = {
        'Matthew 8' => 'MAT.8.NKJV', 'Matthew 9' => 'MAT.9.NKJV',
        'Psalm 5' => 'PSA.5.NKJV', 'Proverbs 1' => 'PRO.1.NKJV'
      }
      assert_select '#readings a[data-b270-passage-link]' do |links|
        assert_equal(bible_com_refs, links.to_h { |link| [link.text, link['href'].split('/').last] })
      end
      assert_track_options('#new_comment_form')

      post "#{day_path(MIXED_DAY)}/comments", params: { comment: { body: 'Wrong track', track: 'ot' } }, headers: TURBO
      assert_response :unprocessable_entity
      post "#{day_path(MIXED_DAY)}/comments", params: { comment: { body: 'On wisdom', track: 'pp' } }
      assert_response :redirect
      reflection = @reader.comments.last
      assert_equal 'pp', reflection.track
      get day_path(MIXED_DAY), params: { edit: reflection.id }
      assert_track_options('.b270-editform')

      @reader.update_passage_source('blue_letter_bible')
      get "#{mount}/reflections"
      assert_select '#comments a.b270-reflink' do |links|
        assert_equal bible_com_refs.keys, links.map(&:text)
        assert_equal(%w[mat/8 mat/9 psa/5 pro/1], links.map { |link| link['href'].split('/')[-4, 2].join('/') })
      end
    end

    def test_disabling_plus95_keeps_shared_reflections_in_lists_and_allows_author_edits_and_deletion
      update_plus95(true)
      extension_author = create_reader('Eli')
      extension = extension_author.comments.create!(day: MIXED_DAY, body: 'Extension reflection')
      base = @reader.comments.create!(day: BASE_DAYS, body: 'Base reflection')
      sign_in_as(extension_author)
      update_plus95(false)

      get "#{mount}/reflections"
      assert_grid_length(BASE_DAYS)
      assert_select '.b270-reflection-count', text: '2 reflections'
      assert_select "#thread-#{base.id}"
      assert_select "#thread-#{extension.id} a[href='#{day_path(MIXED_DAY)}']", text: "Day #{MIXED_DAY}"
      assert_select "select#day option[value='#{MIXED_DAY}']"
      assert_select "select#reader_id option[value='#{extension_author.id}']"
      get "#{mount}/reflections", params: { day: MIXED_DAY, reader_id: extension_author.id }
      assert_select '.b270-reflection-count', text: '1 reflection'
      assert_select "#thread-#{extension.id}"
      assert_select "#thread-#{base.id}", count: 0

      get "#{mount}/readers/#{extension_author.id}"
      assert_select "#comment-#{extension.id}"
      get "#{mount}/progress"
      assert_select "#comment-#{extension.id} a.b270-cedit[href='#{day_path(MIXED_DAY)}?edit=#{extension.id}#comment-#{extension.id}']"
      get day_path(MIXED_DAY), params: { edit: extension.id }
      assert_select "#comment-#{extension.id} form.b270-editform"
      assert_track_options('.b270-editform')
      assert_select '#new_comment_form', count: 0
      patch "#{mount}/comments/#{extension.id}", params: { comment: { body: 'Changed' } }
      assert_redirected_to "#{day_path(MIXED_DAY)}#comment-#{extension.id}"
      assert_equal 'Changed', extension.reload.body

      update_plus95(true)
      get "#{mount}/reflections"
      assert_select '.b270-reflection-count', text: '2 reflections'
      assert_select ".b270-grid a.talk[href='#{day_path(MIXED_DAY)}']"

      update_plus95(false)
      assert_difference('Bible270::Comment.count', -1) do
        delete "#{mount}/comments/#{extension.id}", headers: TURBO
        assert_select "turbo-stream[action='remove'][target='comment-#{extension.id}']"
      end
      get day_path(MIXED_DAY)
      assert_redirected_to "#{mount}/"
    end

    def test_out_of_plan_discussions_allow_likes_and_replies_but_not_new_threads_or_checkoffs
      update_plus95(true)
      author = create_reader('Eli')
      extension = author.comments.create!(day: MIXED_DAY, body: 'Extension reflection')
      hidden = author.comments.create!(day: MIXED_DAY, body: 'Hidden reflection', approved: false)
      hidden_only = author.comments.create!(day: MIXED_DAY + 1, body: 'Another hidden reflection', approved: false)
      update_plus95(false)
      visitor = open_session
      visitor.post "#{day_path(MIXED_DAY)}/comments", params: { comment: { body: 'A reply', parent_id: extension.id } }, headers: TURBO
      visitor.assert_response :unauthorized
      sign_in_as(@reader)

      get day_path(hidden_only.day)
      assert_redirected_to "#{mount}/"
      get day_path(MIXED_DAY), params: { reply_to: hidden.id }
      assert_grid_length(BASE_DAYS)
      assert_select 'h1', text: "Day #{MIXED_DAY} reflections"
      assert_select "#comment-#{extension.id} a[href='#{day_path(MIXED_DAY)}?reply_to=#{extension.id}#new_comment_form']", text: 'Reply'
      assert_select "#comment-#{hidden.id}, #new_comment_form, .b270-daynav, #readings, .b270-toggle", count: 0
      get day_path(MIXED_DAY), params: { reply_to: extension.id }
      assert_select "#new_comment_form input[name='comment[parent_id]'][value='#{extension.id}']"
      assert_track_options('#new_comment_form')

      assert_no_difference('Bible270::Checkoff.count') do
        post "#{day_path(MIXED_DAY)}/toggle/nt/0", params: { checked: '1' }, headers: TURBO
        assert_response :bad_request
      end
      assert_no_difference('Bible270::Comment.count') do
        post "#{day_path(MIXED_DAY)}/comments", params: { comment: { body: 'New reflection' } }
        assert_response :bad_request
        post "#{day_path(MIXED_DAY)}/comments", params: { comment: { body: 'A reply', parent_id: hidden.id } }
        assert_response :bad_request
        post "#{day_path(BASE_DAYS)}/comments", params: { comment: { body: 'A reply', parent_id: extension.id } }, headers: TURBO
        assert_response :unprocessable_entity
        refute_includes response.body, extension.body
        patch "#{mount}/comments/#{extension.id}", params: { comment: { body: 'Changed' } }
        assert_response :not_found
        delete "#{mount}/comments/#{extension.id}"
        assert_response :not_found
      end
      post "#{mount}/comments/#{hidden.id}/like", params: { liked: '1' }, headers: TURBO
      assert_response :not_found
      post "#{mount}/comments/#{extension.id}/like", params: { liked: '1' }
      assert_redirected_to "#{day_path(MIXED_DAY)}#comment-#{extension.id}"
      follow_redirect!
      assert_select "#likes-#{extension.id} .b270-likecount", text: '1'

      post "#{day_path(MIXED_DAY)}/comments", params: { comment: { body: 'A reply', parent_id: extension.id } }, headers: TURBO
      assert_select "turbo-stream[action='append'][target='replies-#{extension.id}'] .b270-cbody", text: 'A reply'
      assert_select "turbo-stream[target='new_comment_form'] input[name='comment[parent_id]'][value='#{extension.id}']"
      reply = extension.replies.find_by!(body: 'A reply')
      post "#{day_path(MIXED_DAY)}/comments", params: { comment: { body: 'Nested reply', parent_id: reply.id } }
      assert_response :bad_request
      get "#{mount}/reflections", params: { day: MIXED_DAY }
      assert_select '.b270-reflection-count', text: '1 reflection'
      assert_select "#thread-#{extension.id} #comment-#{reply.id}"
    end

    def test_historical_base_readers_do_not_inherit_the_new_runs_extension
      Bible270::PlanRun.restart!(start_date: Bible270.today, expected_run_id: @run.id, plus95_enabled: true)
      sign_in_as(@reader)

      get mount
      assert_grid_length(BASE_DAYS)
      get day_path(MIXED_DAY)
      assert_redirected_to "#{mount}/"
      post "#{day_path(MIXED_DAY)}/comments", params: { comment: { body: 'Outside my run' } }
      assert_response :bad_request

      author = create_reader('Eli')
      extension = author.comments.create!(day: MIXED_DAY, body: 'From the current run')
      get "#{mount}/reflections", params: { day: MIXED_DAY }
      assert_select "#thread-#{extension.id}"
      get day_path(MIXED_DAY), params: { reply_to: extension.id }
      assert_grid_length(BASE_DAYS)
      assert_select "#new_comment_form input[name='comment[parent_id]'][value='#{extension.id}']"
      assert_select '#readings, .b270-toggle', count: 0
      post "#{day_path(MIXED_DAY)}/comments", params: { comment: { body: 'Reply from a base reader', parent_id: extension.id } }
      reply = extension.replies.find_by!(body: 'Reply from a base reader')
      assert_redirected_to "#{day_path(MIXED_DAY)}#comment-#{reply.id}"
    end

    def test_historical_plus95_readers_keep_their_calendar_and_global_threads
      update_plus95(true)
      personal_start = @start - 10
      @reader.set_start_date!(personal_start)
      author = create_reader('Eli')
      extension = author.comments.create!(day: MIXED_DAY, body: 'From the previous run')
      Bible270::PlanRun.restart!(start_date: Bible270.today, expected_run_id: @run.id)
      author.activate! # The reflection remains visible regardless of the author's new run.
      visitor = open_session
      visitor.get day_path(MIXED_DAY)
      visitor.assert_response :success
      visitor.assert_select "#comment-#{extension.id}"
      visitor.assert_select '#readings, #new_comment_form, .b270-toggle', count: 0
      visitor.get "#{mount}/readers/#{@reader.id}"
      visitor.assert_select '.b270-grid a.b270-cell', count: BASE_DAYS
      visitor.assert_select '.b270-grid span.b270-cell', count: EXTENDED_DAYS - BASE_DAYS

      sign_in_as(@reader)
      get day_path(MIXED_DAY), params: { reply_to: extension.id }
      assert_grid_length(EXTENDED_DAYS)
      assert_select '.b270-dayhead .date', text: %r{#{formatted_date(personal_start + MIXED_DAY - 1)}}
      assert_select "#comment-#{extension.id}"
      assert_select '.b270-replying strong', text: author.display_name
      assert_select '.b270-toggle', count: 0
      post "#{day_path(MIXED_DAY)}/comments", params: { comment: { body: 'Reply from an alumnus', parent_id: extension.id } }
      assert_response :redirect
      get "#{mount}/reflections"
      assert_select "#thread-#{extension.id} .b270-reply .b270-cbody", text: 'Reply from an alumnus'
      get "#{mount}/readers/#{author.id}"
      assert_select "#comment-#{extension.id}"
    end

  private

    def mount = Bible270.config.mount_at.chomp('/')
    def day_path(day) = "#{mount}/day/#{day}"
    def formatted_date(date) = date.strftime('%B %-d, %Y')

    def create_reader(name)
      email = "#{name.downcase}@example.org"
      Bible270::Reader.create!(provider: 'email', uid: email, email: email,
                               first_name: name, last_name: 'Reader', display_name: "#{name} Reader")
    end

    def sign_in_as(reader)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"
    end

    def update_plus95(enabled)
      Bible270::PlanRun.update_plus95!(enabled: enabled, expected_run_id: @run.id)
    end

    def assert_grid_length(days)
      assert_response :success
      assert_select '.b270-index summary', text: "View all #{days} days"
      assert_select '.b270-grid a.b270-cell', count: days
    end

    def assert_track_options(form)
      assert_select "#{form} select[name='comment[track]'] option" do |options|
        assert_equal(['', 'nt', 'pp'], options.map { |option| option['value'] })
      end
    end
  end
end
