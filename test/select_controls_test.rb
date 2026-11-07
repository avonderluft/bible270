# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class SelectControlsTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_config = %i[daily_reminders admin_emails admin_resolver current_reader_resolver
                            mention_notifications registration_notice_deliver_later].to_h do |key|
        [key, Bible270.config.public_send(key)]
      end
      Bible270.config.daily_reminders = true
      Bible270.config.admin_resolver = nil
      Bible270.config.current_reader_resolver = nil
      Bible270.config.mention_notifications = false
      Bible270.config.registration_notice_deliver_later = false
      @reader = Bible270::Reader.create!(provider: 'email', uid: 'selects@example.org',
                                         email: 'selects@example.org', display_name: 'Zoe Aaronson',
                                         first_name: 'Zoe', last_name: 'Aaronson', bible_version: 'ESV',
                                         display_mode: 'dark_blue', daily_reminders: true,
                                         daily_reminder_time: '06:45')
      Bible270.config.admin_emails = [@reader.email]
      _record, raw = Bible270::SignInToken.issue!(@reader.email)
      get "#{mount}/sign_in/email/#{raw}"
    end

    def teardown
      @previous_config&.each { |key, value| Bible270.config.public_send("#{key}=", value) }
    end

    def test_profile_wraps_translation_theme_and_reminder_controls_without_changing_submission
      get "#{mount}/profile"

      assert_wrapped_selects(5)
      assert_header_theme
      assert_select 'span.b270-select-wrap--full > select#bible_version[name="bible_version"] option[value="ESV"][selected]'
      assert_select 'span.b270-select-wrap--full > select#display_mode[name="display_mode"][data-b270-theme-apply="true"] option[value="dark_blue"][selected]'
      assert_select ".b270-time-control[role='group'][aria-label='Reminder time'][aria-describedby='daily-reminder-time-hint']" do
        assert_select 'span.b270-select-wrap--compact.b270-select-wrap--time > select[name="daily_reminder_hour"][aria-label="Hour"][required] option[value="06"][selected]'
        assert_select 'span.b270-select-wrap--compact.b270-select-wrap--time > select[name="daily_reminder_minute"][aria-label="Minute"][required] option[value="45"][selected]'
      end

      patch "#{mount}/profile", params: {
        first_name: 'Zoe', last_name: 'Aaronson', bible_version: 'KJV', display_mode: 'sage',
        daily_reminders: '1', daily_reminder_hour: '07', daily_reminder_minute: '30'
      }
      assert_response :redirect
      @reader.reload
      assert_equal 'KJV', @reader.bible_version
      assert_equal 'sage', @reader.display_mode
      assert @reader.daily_reminders
      assert_equal '07:30', @reader.daily_reminder_time
    end

    def test_admin_index_wraps_sort_and_audience_and_preserves_sorting
      other = Bible270::Reader.create!(provider: 'email', uid: 'other-selects@example.org',
                                       email: 'other-selects@example.org', display_name: 'Amy Zebedee',
                                       first_name: 'Amy', last_name: 'Zebedee')
      get "#{mount}/admin", params: { sort: 'last_name' }

      assert_wrapped_selects(3)
      assert_select "form.b270-admin-reader-sort[action='#{mount}/admin'][method='get']" do
        assert_select 'label > span', text: 'Sort readers by'
        assert_select 'select[name="sort"] option[value="last_name"][selected]'
      end
      assert_equal [@reader.display_name, other.display_name], css_select('.b270-list .name > a').map(&:text)
      assert_select "form[action='#{mount}/admin/broadcast'][method='post']" do
        assert_select 'label[for="b270-broadcast-audience"]', text: 'Recipients'
        assert_select 'span.b270-select-wrap--full > select#b270-broadcast-audience[name="audience"]' do
          assert_select 'option[value="everyone"][selected]'
          assert_select 'option[value="admins"]'
        end
      end
    end

    def test_admin_reader_wraps_translation_and_theme_without_changing_wiring
      get "#{mount}/admin/readers/#{@reader.id}"

      assert_wrapped_selects(3)
      assert_select "form[action='#{mount}/admin/readers/#{@reader.id}/version']" do
        assert_select 'input[name="_method"][value="patch"]'
        assert_select 'span.b270-select-wrap--full > select[name="bible_version"][aria-label="Bible translation"]' do
          assert_select 'option[value=""]', text: %r{Site default}
          assert_select 'option[value="ESV"][selected]'
        end
      end
      assert_select "form[action='#{mount}/admin/readers/#{@reader.id}/theme']" do
        assert_select 'input[name="_method"][value="patch"]'
        assert_select 'span.b270-select-wrap--full > select[name="display_mode"][aria-labelledby="b270-theme-heading"][aria-describedby="b270-theme-hint b270-theme-status"]' do
          assert_select 'option[value="dark_blue"][selected]'
        end
        assert_select "select[data-b270-theme-url='#{mount}/admin/readers/#{@reader.id}/theme'][data-b270-saved-theme='dark_blue']"
      end
    end

    def test_reflection_filters_are_wrapped_and_keep_selected_filters
      reflection = @reader.comments.create!(day: 1, body: 'A reflection to filter', track: 'ot')
      other_reflection = @reader.comments.create!(day: 2, body: 'Another day to filter', track: 'ot')
      get "#{mount}/reflections", params: { day: 1, reader_id: @reader.id }

      assert_wrapped_selects(3)
      assert_select "form.b270-reflection-filters[action='#{mount}/reflections'][method='get']" do
        assert_select 'label > span', text: 'Day'
        assert_select 'label > span', text: 'Reflection by'
        assert_select 'select[name="day"] option[value="1"][selected]'
        assert_select "select[name='reader_id'] option[value='#{@reader.id}'][selected]"
      end
      assert_select "#thread-#{reflection.id}"

      get "#{mount}/reflections", params: { day: 2, reader_id: @reader.id }
      assert_wrapped_selects(3)
      assert_select "#thread-#{reflection.id}", count: 0
      assert_select "#thread-#{other_reflection.id}"
    end

    def test_day_add_and_edit_track_controls_are_wrapped_and_submit_the_selected_track
      get "#{mount}/day/1"

      assert_wrapped_selects(2)
      assert_select "form#new_comment_form[action='#{mount}/day/1/comments']" do
        assert_track_select
        assert_select 'select[name="comment[track]"] option[value=""]', text: 'The whole day'
      end
      post "#{mount}/day/1/comments", params: { comment: { body: 'A selected reading', track: 'ot' } }
      assert_response :redirect
      reflection = @reader.comments.find_by!(body: 'A selected reading')
      assert_equal 'ot', reflection.track

      get "#{mount}/day/1", params: { edit: reflection.id }
      assert_wrapped_selects(3)
      assert_select "form.b270-editform[action='#{mount}/comments/#{reflection.id}']" do
        assert_track_select
        assert_select 'input[name="_method"][value="patch"]'
        assert_select 'select[name="comment[track]"] option[value="ot"][selected]'
      end
      patch "#{mount}/comments/#{reflection.id}", params: { comment: { body: 'A selected reading', track: 'pp' } }
      assert_response :redirect
      assert_equal 'pp', reflection.reload.track
    end

  private

    def mount = Bible270.config.mount_at.chomp('/')

    def assert_wrapped_selects(count)
      assert_response :success
      selects = css_select('select')
      assert_equal count, selects.size
      selects.each do |select|
        wrapper = select.parent
        assert_equal 'span', wrapper.name, "#{select['name']} must have an immediate span wrapper"
        assert_includes wrapper['class'].to_s.split, 'b270-select-wrap', "missing shared wrapper for #{select['name']}"
        assert_equal [select], wrapper.element_children.to_a, 'the wrapper should contain only its native select'
        labelled = select['aria-label'].present? || select['aria-labelledby'].present? ||
                   select.ancestors('label').any? || css_select("label[for='#{select['id']}']").any?
        assert labelled, "#{select['name']} must keep an accessible label"
        %w[aria-labelledby aria-describedby].each do |attribute|
          select[attribute].to_s.split.each { |id| assert_select "[id='#{id}']", count: 1 }
        end
      end
    end

    def assert_header_theme
      assert_select "form.b270-header-theme[action='#{mount}/profile/theme']" do
        assert_select 'input[name="_method"][value="patch"]'
        assert_select 'span.b270-select-wrap--compact > select#b270-header-theme[name="display_mode"][aria-label="Theme"][aria-describedby="b270-header-theme-status"]' do
          assert_select 'option[value="dark_blue"][selected]', text: 'Moonlight'
        end
        assert_select "select[data-b270-theme-url='#{mount}/profile/theme'][data-b270-theme-apply='true'][data-b270-theme-status='b270-header-theme-status']"
      end
    end

    def assert_track_select
      assert_select 'span.b270-select-wrap.b270-track-select-wrap > select[name="comment[track]"][aria-label="Reading this reflection relates to"]' do
        assert_select 'option', count: 4
        assert_select 'option[value="ot"]'
        assert_select 'option[value="pp"]'
      end
    end
  end
end
