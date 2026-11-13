# frozen_string_literal: true

require_relative '../test_helper'
require 'tempfile'
require 'image_processing/vips'

if RAILS_LOADED
  class Bible270ProfilesControllerTestCase < ActionDispatch::IntegrationTest
    # Uploads must own their commit boundary; files cannot join a DB rollback.
    self.use_transactional_tests = false

    def setup
      needs_rails!
      clear_engine_tables!
      @previous_time_zone = Bible270.config.time_zone
      @previous_daily_reminders = Bible270.config.daily_reminders
      Bible270.config.daily_reminders = false
      @reader = Bible270::Reader.create!(provider: 'email', uid: 'r@example.org',
                                         email: 'r@example.org', display_name: 'R Reader',
                                         first_name: 'R', last_name: 'Reader')
    end

    def teardown
      Bible270.config.time_zone = @previous_time_zone
      Bible270.config.daily_reminders = @previous_daily_reminders
    end

    def mount = Bible270.config.mount_at.chomp('/')

    def sign_in_as(reader)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"
    end

  private

    def complete_profile_params
      {
        first_name: '  New   First  ', last_name: " von\u00A0 Last ", bible_version: ' lsb ',
        passage_source: 'blue_letter_bible', display_mode: 'dark_green', comment_notifications: 'personal',
        daily_reminders: '1', daily_reminder_hour: '06', daily_reminder_minute: '45'
      }
    end

    def prepare_profile_with_avatar(optimized: false)
      skip 'Active Storage unavailable' unless Bible270::Reader.avatar_uploads?

      Bible270.config.daily_reminders = true
      @reader.update!(bible_version: 'KJV', passage_source: 'bible_gateway', display_mode: 'dark_blue',
                      notify_on_mention: false, notify_on_all_comments: false,
                      daily_reminders: false, daily_reminder_time: '09:30')
      @reader.avatar.attach(io: StringIO.new('original avatar'), filename: 'original.png', content_type: 'image/png')
      if optimized
        with_uploaded_avatar do |upload|
          Bible270::AvatarImages.update!(@reader, {}, upload: upload)
        end
      end
      sign_in_as(@reader)
    end

    def avatar_png
      @avatar_png ||= Vips::Image.black(480, 320).new_from_image([35, 120, 210]).write_to_buffer('.png')
    end

    def with_uploaded_avatar(content_type: 'image/png', contents: avatar_png)
      file = Tempfile.new(['avatar', '.png'])
      file.binmode
      file.write(contents)
      file.rewind
      yield Rack::Test::UploadedFile.new(file.path, content_type, true, original_filename: 'replacement.png')
    ensure
      file&.close!
    end

    def assert_profile_unchanged(allow_storage_writes: false, &block)
      attributes = @reader.reload.attributes
      attachment = @reader.avatar.attachment.attributes
      blob = @reader.avatar.blob.attributes
      original_bytes = @reader.avatar.download
      thumbnail = @reader.avatar_thumbnail.attachment&.attributes
      thumbnail_blob = @reader.avatar_thumbnail.blob&.attributes
      thumbnail_bytes = @reader.avatar_thumbnail.download if thumbnail
      storage_writes = []
      subscriber = ->(*event) { storage_writes << event.first }
      ActiveSupport::Notifications.subscribed(subscriber, %r{service_(upload|delete|delete_prefixed)\.active_storage}) do
        assert_no_difference ['ActiveStorage::Blob.count', 'ActiveStorage::Attachment.count'], &block
      end
      assert_empty storage_writes unless allow_storage_writes
      assert_equal attributes, @reader.reload.attributes
      assert_equal attachment, @reader.avatar.attachment.attributes
      assert_equal blob, @reader.avatar.blob.attributes
      assert_equal original_bytes, @reader.avatar.download
      if thumbnail
        assert_equal thumbnail, @reader.avatar_thumbnail.attachment.attributes
        assert_equal thumbnail_blob, @reader.avatar_thumbnail.blob.attributes
        assert_equal thumbnail_bytes, @reader.avatar_thumbnail.download
      else
        refute @reader.avatar_thumbnail.attached?
      end
    end
  end
end
