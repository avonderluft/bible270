# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class ProfilesControllerTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @reader = Bible270::Reader.create!(provider: 'email', uid: 'r@example.org',
                                         email: 'r@example.org', display_name: 'R Reader',
                                         first_name: 'R', last_name: 'Reader')
    end

    def mount = Bible270.config.mount_at.chomp('/')

    def sign_in_as(reader)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"
    end

    def test_a_visitor_is_sent_to_sign_in
      get "#{mount}/profile"

      assert_response :redirect
      assert_match(%r{sign_in}, response.location)
    end

    def test_a_reader_sees_the_form
      sign_in_as(@reader)
      get "#{mount}/profile"

      assert_response :success
      assert_match(%r{first_name}, response.body)
      assert_match(%r{last_name}, response.body)
    end

    def test_a_name_can_be_changed
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'Andrew', last_name: 'vonderLuft' }

      assert_response :redirect
      @reader.reload
      assert_equal 'Andrew', @reader.first_name
      assert_equal 'vonderLuft', @reader.last_name
      assert_equal 'Andrew vonderLuft', @reader.display_name
    end

    def test_half_a_name_is_refused_and_the_form_comes_back
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'Andrew', last_name: '' }

      assert_response :unprocessable_entity
      assert_equal 'R', @reader.reload.first_name, 'nothing should have changed'
    end

    def test_a_translation_can_be_chosen
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'R', last_name: 'Reader', bible_version: 'LSB' }

      assert_equal 'LSB', @reader.reload.bible_version
      assert_equal 'LSB', @reader.effective_bible_version
    end

    def test_an_unknown_translation_is_refused
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'R', last_name: 'Reader', bible_version: 'NIV' }

      assert_response :unprocessable_entity
      assert_nil @reader.reload.bible_version
    end

    # Reading links should open in whatever the reader chose.
    def test_the_chosen_translation_reaches_the_day_page
      sign_in_as(@reader)
      patch "#{mount}/profile", params: { first_name: 'R', last_name: 'Reader', bible_version: 'KJV' }
      get "#{mount}/day/1"

      assert_response :success
      assert_match(%r{\(KJV\)}, response.body)
    end

    def test_a_picture_can_be_removed
      skip 'Active Storage unavailable' unless Bible270::Reader.avatar_uploads?

      @reader.avatar.attach(io: StringIO.new('x'), filename: 'a.png', content_type: 'image/png')
      assert @reader.reload.avatar_uploaded?

      sign_in_as(@reader)
      delete "#{mount}/profile/avatar"

      refute @reader.reload.avatar_uploaded?
    end

    def test_a_visitor_cannot_remove_a_picture
      delete "#{mount}/profile/avatar"

      assert_response :redirect
      assert_match(%r{sign_in}, response.location)
    end
  end
end
