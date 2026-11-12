# frozen_string_literal: true

require_relative 'support/profiles_controller_test_case'

if RAILS_LOADED
  class ProfilesControllerTest < Bible270ProfilesControllerTestCase
    def test_a_visitor_is_sent_to_sign_in
      get "#{mount}/profile"

      assert_response :redirect
      assert_match(%r{sign_in}, response.location)
    end

    def test_a_reader_sees_the_form
      sign_in_as(@reader)
      get "#{mount}/profile"

      assert_response :success
      assert_select 'p.b270-eyebrow', text: 'Profile'
      assert_select 'h1', text: 'Your details'
      assert_match(%r{first_name}, response.body)
      assert_match(%r{last_name}, response.body)
      assert_match(%r{value="HEB/GRK".*value="ALLGRK"}m, response.body)
      assert_select 'fieldset.b270-notification-field' do
        assert_select 'legend', text: 'Reflection emails'
        assert_select 'input[type="radio"][name="comment_notifications"]', count: 3
        assert_select 'input[value="all"][checked="checked"]', count: 1
        assert_select 'label', text: %r{Every new reflection and reply}
        assert_select 'label', text: %r{Only replies to my reflections and mentions of me}
        assert_select 'label', text: %r{None}
      end
      refute_match(%r{name="daily_reminders"}, response.body)
      refute_match(%r{name="daily_reminder_time"}, response.body)
      assert_match(%r{name="bible_version".*class="b270-source-choices"}m, response.body,
                   'reader choice belongs immediately below the translation selector')
      assert_equal 3, response.body.scan(%r{name="passage_source"}).size
      assert_match(%r{\.b270-source-choices\{.*?flex-wrap:nowrap}m, response.body)
      assert_match(%r{value="bible_com" checked="checked"}, response.body)
      assert_operator response.body.index('Bible.com'), :<, response.body.index('Bible Gateway')
      assert_operator response.body.index('Bible Gateway'), :<, response.body.index('Blue Letter Bible')
      assert_select "a[href='#{mount}/progress']", text: '← Back to your progress'
    end

    def test_the_profile_page_expands_the_day_index
      sign_in_as(@reader)

      get "#{mount}/profile"

      assert_select 'details.b270-index[open]' do
        assert_select 'summary', text: 'View all 270 days'
      end
    end

    def test_original_languages_offer_blue_letter_bible_and_bible_com
      @reader.update_bible_version('HEB/GRK')
      sign_in_as(@reader)
      get "#{mount}/profile"

      blue_letter = response.body.match(%r{<input[^>]*value="blue_letter_bible"[^>]*>}).to_s
      bible_com = response.body.match(%r{<input[^>]*value="bible_com"[^>]*>}).to_s
      gateway = response.body.match(%r{<input[^>]*value="bible_gateway"[^>]*>}).to_s
      refute_includes blue_letter, 'checked="checked"'
      refute_includes blue_letter, 'disabled="disabled"'
      assert_includes bible_com, 'checked="checked"'
      refute_includes bible_com, 'disabled="disabled"'
      refute_includes gateway, 'checked="checked"'
      assert_includes gateway, 'disabled="disabled"'
    end

    def test_all_greek_offers_blue_letter_bible_and_bible_com
      @reader.update_bible_version('ALLGRK')
      sign_in_as(@reader)
      get "#{mount}/profile"

      assert_select 'input[name="passage_source"][value="bible_com"][checked="checked"]'
      assert_select 'input[name="passage_source"][value="blue_letter_bible"]:not([disabled])'
      assert_select 'input[name="passage_source"][value="bible_gateway"][disabled="disabled"]'
    end

    def test_a_name_can_be_changed
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'Andrew', last_name: 'vonderLuft' }

      assert_response :redirect
      assert_equal "#{mount}/profile", URI.parse(response.location).path
      @reader.reload
      assert_equal 'Andrew', @reader.first_name
      assert_equal 'vonderLuft', @reader.last_name
      assert_equal 'Andrew vonderLuft', @reader.display_name
    end

    def test_half_a_name_is_refused_and_the_form_comes_back
      @reader.update_comment_notification_level!('none')
      sign_in_as(@reader)
      patch "#{mount}/profile", params: {
        first_name: 'Andrew', last_name: '', comment_notifications: 'all'
      }

      assert_response :unprocessable_entity
      assert_equal 'R', @reader.reload.first_name, 'nothing should have changed'
      assert_equal 'none', @reader.comment_notification_level,
                   'notification preference should not change on an invalid form'
      assert_select 'input[name="comment_notifications"][value="all"][checked="checked"]'
    end

    def test_a_translation_can_be_chosen
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'R', last_name: 'Reader', bible_version: 'LSB' }

      assert_equal 'LSB', @reader.reload.bible_version
      assert_equal 'LSB', @reader.effective_bible_version
    end

    def test_blue_letter_bible_can_be_chosen
      sign_in_as(@reader)
      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', bible_version: 'LSB', passage_source: 'blue_letter_bible'
      }

      assert_equal 'blue_letter_bible', @reader.reload.passage_source
    end

    def test_bible_com_can_be_chosen
      sign_in_as(@reader)
      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', bible_version: 'LSB', passage_source: 'bible_com'
      }

      assert_equal 'bible_com', @reader.reload.passage_source
    end

    def test_an_unknown_passage_source_is_refused
      sign_in_as(@reader)
      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', bible_version: 'LSB', passage_source: 'unknown'
      }

      assert_response :unprocessable_entity
      assert_equal 'bible_com', @reader.reload.passage_source
    end

    def test_omitting_the_passage_source_returns_to_the_default
      @reader.update!(passage_source: 'blue_letter_bible')
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'R', last_name: 'Reader', bible_version: 'LSB' }

      assert_equal 'bible_com', @reader.reload.passage_source
    end

    def test_an_unknown_translation_is_refused
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'R', last_name: 'Reader', bible_version: 'NIV' }

      assert_response :unprocessable_entity
      assert_nil @reader.reload.bible_version
    end

    # Reading links should open in whatever the reader chose.
    def test_the_chosen_translation_uses_bible_com_by_default
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'R', last_name: 'Reader', bible_version: 'KJV' }
      get "#{mount}/day/1"

      assert_response :success
      assert_match(%r{\(KJV\)}, response.body)
      assert_match(%r{www\.bible\.com/bible/1/GEN\.1\.KJV}, response.body)
    end

    def test_the_bible_gateway_choice_reaches_the_day_page
      sign_in_as(@reader)
      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', bible_version: 'KJV', passage_source: 'bible_gateway'
      }
      get "#{mount}/day/1"

      assert_response :success
      assert_match(%r{biblegateway\.com.*version=KJV}, response.body)
    end

    def test_the_blue_letter_bible_choice_reaches_the_day_page
      sign_in_as(@reader)
      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', bible_version: 'KJV', passage_source: 'blue_letter_bible'
      }
      get "#{mount}/day/1"

      assert_response :success
      assert_match(%r{blueletterbible\.org/kjv/gen/1/1/s_1001}, response.body)
      refute_match(%r{biblegateway\.com}, response.body)
    end

    def test_the_bible_com_choice_reaches_the_day_page
      sign_in_as(@reader)
      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', bible_version: 'KJV', passage_source: 'bible_com'
      }
      get "#{mount}/day/1"

      assert_response :success
      passage_hrefs = css_select('a[data-b270-passage-link="true"]').map { |link| link['href'] }
      assert(passage_hrefs.all? { |href| href.start_with?('https://www.bible.com/bible/') })
      assert_includes passage_hrefs, 'https://www.bible.com/bible/1/GEN.1.KJV'
    end

    def test_original_languages_use_bible_com_when_selected
      sign_in_as(@reader)
      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', bible_version: 'HEB/GRK', passage_source: 'bible_com'
      }
      get "#{mount}/day/1"

      assert_response :success
      assert_match(%r{www\.bible\.com/bible/3585/GEN\.1\.WLC}, response.body)
      assert_match(%r{www\.bible\.com/bible/2270/MAT\.1\.THGNT}, response.body)
    end

    def test_all_greek_uses_lxx_and_thgnt_on_bible_com
      sign_in_as(@reader)
      patch "#{mount}/profile", params: {
        first_name: 'R', last_name: 'Reader', bible_version: 'ALLGRK', passage_source: 'bible_com'
      }
      get "#{mount}/day/1"

      assert_response :success
      assert_match(%r{www\.bible\.com/bible/2503/GEN\.1\.GRCBRENT}, response.body)
      assert_match(%r{www\.bible\.com/bible/2270/MAT\.1\.THGNT}, response.body)
    end
  end
end
