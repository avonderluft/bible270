# frozen_string_literal: true

require 'test_helper'

# How readers come into existence, and the derived values shown about them.
if RAILS_LOADED
  class ReaderIdentityTest < Minitest::Test
    def setup
      needs_rails!
      clear_engine_tables!
    end

    # A plain hash, not an OmniAuth::AuthHash or OpenStruct: Reader.dig_auth reads
    # through [], and ostruct is no longer a default gem in Ruby 4.0.
    def auth(overrides = {})
      {
        'provider' => 'github', 'uid' => '12345',
        'info' => { 'name' => 'Andrew vonderLuft', 'email' => 'andrew@example.org',
                    'image' => 'https://example.org/face.png' }
      }.merge(overrides)
    end

    # ---- OmniAuth ----------------------------------------------------------

    def test_a_reader_is_created_from_an_auth_hash
      reader = Bible270::Reader.from_omniauth(auth)

      assert_equal 'github', reader.provider
      assert_equal '12345', reader.uid
      assert_equal 'Andrew vonderLuft', reader.display_name
      assert_equal 'andrew@example.org', reader.email
      assert_equal 'https://example.org/face.png', reader.avatar_url
    end

    def test_signing_in_again_finds_the_same_reader
      first = Bible270::Reader.from_omniauth(auth)
      again = Bible270::Reader.from_omniauth(auth)

      assert_equal first.id, again.id
      assert_equal 1, Bible270::Reader.count
    end

    def test_the_same_uid_from_another_provider_is_a_different_person
      Bible270::Reader.from_omniauth(auth)
      Bible270::Reader.from_omniauth(auth('provider' => 'gitlab'))

      assert_equal 2, Bible270::Reader.count
    end

    def test_a_changed_name_or_picture_is_picked_up
      reader = Bible270::Reader.from_omniauth(auth)
      Bible270::Reader.from_omniauth(
        auth('info' => { 'name' => 'A. vonderLuft', 'email' => 'andrew@example.org',
                         'image' => 'https://example.org/new.png' })
      )

      reader.reload
      assert_equal 'A. vonderLuft', reader.display_name
      assert_equal 'https://example.org/new.png', reader.avatar_url
    end

    def test_a_reader_without_a_name_still_gets_one
      reader = Bible270::Reader.from_omniauth(auth('info' => { 'email' => 'nameless@example.org' }))

      refute_empty reader.display_name.to_s, 'a blank display name would render as an empty link'
    end

    # Providers usually give one display name. Without splitting it the reader had
    # no first_name, which made the greeting read "Welcome ." and left them
    # unmentionable — Reader.mentioned_in only considers readers who have one.
    def test_a_display_name_is_split_into_first_and_last
      reader = Bible270::Reader.from_omniauth(auth)

      assert_equal 'Andrew', reader.first_name
      assert_equal 'vonderLuft', reader.last_name
    end

    def test_a_single_word_name_still_gives_a_first_name
      reader = Bible270::Reader.from_omniauth(auth('info' => { 'name' => 'Madonna' }))

      assert_equal 'Madonna', reader.first_name
      assert_nil reader.last_name
    end

    def test_explicit_name_fields_are_preferred_when_given
      reader = Bible270::Reader.from_omniauth(
        auth('info' => { 'name' => 'ignored', 'first_name' => 'Mary', 'last_name' => 'Smith' })
      )

      assert_equal 'Mary', reader.first_name
      assert_equal 'Smith', reader.last_name
    end

    # A reader who corrects their name on their profile keeps it.
    def test_signing_in_again_does_not_overwrite_a_corrected_name
      reader = Bible270::Reader.from_omniauth(auth)
      reader.update_names('Andy', 'vonderLuft')

      Bible270::Reader.from_omniauth(auth)

      assert_equal 'Andy', reader.reload.first_name
    end

    def test_an_omniauth_reader_can_be_mentioned
      Bible270::Reader.from_omniauth(auth)

      assert_equal ['Andrew vonderLuft'],
                   Bible270::Reader.mentioned_in('thanks @andrew').map(&:display_name)
    end

    def test_existing_omniauth_readers_can_be_recognised
      Bible270::Reader.from_omniauth(auth)

      assert Bible270::Reader.omniauth_reader_exists?('github', '12345')
      refute Bible270::Reader.omniauth_reader_exists?('github', 'someone-else')
    end

    # ---- bridged host users ------------------------------------------------

    def test_a_host_user_can_be_bridged_in
      owner = HostUser.create!(name: 'Host User')
      reader = Bible270::Reader.for_owner(owner, display_name: 'Host User', email: 'host@example.org')

      assert_equal 'Host User', reader.display_name
      assert_equal 'host@example.org', reader.email
      assert_equal owner.id, reader.owner_id
    end

    def test_bridging_the_same_owner_twice_reuses_the_reader
      owner = HostUser.create!(name: 'Host User')
      first = Bible270::Reader.for_owner(owner, display_name: 'Host User')
      again = Bible270::Reader.for_owner(owner, display_name: 'Host User')

      assert_equal first.id, again.id
      assert_equal 1, Bible270::Reader.count
    end

    def test_two_host_users_are_two_readers
      Bible270::Reader.for_owner(HostUser.create!(name: 'One'), display_name: 'One')
      Bible270::Reader.for_owner(HostUser.create!(name: 'Two'), display_name: 'Two')

      assert_equal 2, Bible270::Reader.count
    end

    # ---- derived values ----------------------------------------------------

    def test_initials_come_from_the_display_name
      reader = Bible270::Reader.create!(provider: 'email', uid: 'a@example.org',
                                        email: 'a@example.org', display_name: 'Andrew vonderLuft')
      assert_equal 'AV', reader.initials

      reader.update!(display_name: 'Madonna')
      assert_equal 'M', reader.initials
    end

    def test_completion_is_a_whole_percentage
      reader = Bible270::Reader.create!(provider: 'email', uid: 'b@example.org',
                                        email: 'b@example.org', display_name: 'B Reader')
      assert_equal 0, reader.completion_percent

      reader.mark_through!(27) # a tenth of 270
      assert_equal 10, reader.completion_percent
    end

    def test_the_next_day_to_read_is_the_first_unfinished_one
      reader = Bible270::Reader.create!(provider: 'email', uid: 'c@example.org',
                                        email: 'c@example.org', display_name: 'C Reader')
      assert_equal 1, reader.current_day

      reader.mark_through!(5)
      assert_equal 6, reader.current_day
    end

    def test_an_undated_reader_has_no_calendar_position
      reader = Bible270::Reader.create!(provider: 'email', uid: 'd@example.org',
                                        email: 'd@example.org', display_name: 'D Reader')

      refute reader.dated? if Bible270.config.start_date.nil?
      assert_nil reader.today_day if Bible270.config.start_date.nil?
    end

    def test_pace_is_measured_against_the_calendar
      reader = Bible270::Reader.create!(provider: 'email', uid: 'e@example.org',
                                        email: 'e@example.org', display_name: 'E Reader')
      reader.set_start_date!((Bible270.today - 9).to_s) # today is day 10

      assert_equal 10, reader.calendar_day
      # Positive means behind: the calendar is ahead of what has been read.
      assert_equal 10, reader.days_off_pace, 'nothing read, ten days in'

      reader.mark_through!(10)
      assert_equal 0, reader.days_off_pace, 'exactly on pace'

      reader.mark_through!(12)
      assert_equal(-2, reader.days_off_pace, 'two days ahead reads as negative')
    end

    def test_the_end_date_is_the_start_plus_the_plan
      reader = Bible270::Reader.create!(provider: 'email', uid: 'f@example.org',
                                        email: 'f@example.org', display_name: 'F Reader')
      reader.set_start_date!('2026-09-06')

      assert_equal Date.new(2026, 9, 6) + Bible270::Plan::DAYS - 1, reader.plan_end_date
    end

    def test_a_translation_choice_falls_back_to_the_site_default
      reader = Bible270::Reader.create!(provider: 'email', uid: 'g@example.org',
                                        email: 'g@example.org', display_name: 'G Reader')

      assert_nil reader.bible_version
      assert_equal Bible270.config.bible_version, reader.effective_bible_version

      reader.update_bible_version('KJV')
      assert_equal 'KJV', reader.effective_bible_version
      assert_equal 'King James Version', reader.bible_version_label
    end
  end
end
