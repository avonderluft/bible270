# frozen_string_literal: true

require_relative '../test_helper'
require 'tempfile'
require 'image_processing/vips'

if RAILS_LOADED
  class Bible270AdminControllerTestCase < ActionDispatch::IntegrationTest
    # Uploads must own their commit boundary; files cannot join a DB rollback.
    self.use_transactional_tests = false

    def setup
      needs_rails!
      clear_engine_tables!
      @previous_admins = Bible270.config.admin_emails
      @previous_admin_resolver = Bible270.config.admin_resolver
      @previous_deliver_later = Bible270.config.registration_notice_deliver_later
      @previous_start_date = Bible270.config.start_date
      @previous_personal_dates = Bible270.config.allow_reader_start_date
      @previous_mention_notifications = Bible270.config.mention_notifications
      Bible270.config.admin_resolver = nil
      Bible270.config.registration_notice_deliver_later = false
      @admin = Bible270::Reader.create!(provider: 'email', uid: 'boss@example.org',
                                        email: 'boss@example.org', display_name: 'The Boss')
      @reader = Bible270::Reader.create!(provider: 'email', uid: 'r@example.org',
                                         email: 'r@example.org', display_name: 'R Reader',
                                         first_name: 'R', last_name: 'Reader')
    end

    def teardown
      Bible270.config.admin_emails = @previous_admins
      Bible270.config.admin_resolver = @previous_admin_resolver
      Bible270.config.registration_notice_deliver_later = @previous_deliver_later
      Bible270.config.start_date = @previous_start_date
      Bible270.config.allow_reader_start_date = @previous_personal_dates
      Bible270.config.mention_notifications = @previous_mention_notifications
      Bible270::Setting.open_enrollment!
      Bible270::Setting.clear_run_start_date!
    end

    def mount = Bible270.config.mount_at.chomp('/')

    def sign_in_as(reader)
      _record, raw = Bible270::SignInToken.issue!(reader.email)
      get "#{mount}/sign_in/email/#{raw}"
    end

    def sign_in_as_admin
      Bible270.config.admin_emails = [@admin.email]
      sign_in_as(@admin)
    end

    def assert_reader_order(*readers)
      reader_list = css_select('.b270-list').first.to_s
      readers.each_cons(2) do |first, second|
        assert_operator reader_list.index(first.display_name), :<, reader_list.index(second.display_name)
      end
    end

    def assert_reader_stats_order(*readers)
      stats = css_select('#b270-reader-stats-dialog pre').first.text
      readers.each_cons(2) do |first, second|
        assert_operator stats.index(first.display_name), :<, stats.index(second.display_name)
      end
    end

    def avatar_png
      @avatar_png ||= Vips::Image.black(480, 320).new_from_image([35, 120, 210]).write_to_buffer('.png')
    end

    def with_uploaded_avatar(content_type: 'image/png', contents: avatar_png)
      file = Tempfile.new(['avatar', '.png'])
      file.binmode
      file.write(contents)
      file.rewind
      upload = Rack::Test::UploadedFile.new(
        file.path, content_type, true, original_filename: 'avatar.png'
      )
      yield upload
    ensure
      file&.close!
    end

    def prepare_admin_avatar
      skip 'Active Storage unavailable' unless Bible270::Reader.avatar_uploads?

      with_uploaded_avatar { |upload| Bible270::AvatarImages.update!(@reader, {}, upload: upload) }
      sign_in_as_admin
    end

    def assert_admin_avatar_unchanged(allow_storage_writes: false, &block)
      attributes = @reader.reload.attributes
      images = [@reader.avatar, @reader.avatar_thumbnail]
      attachments = images.map { |image| image.attachment.attributes }
      blobs = images.map { |image| image.blob.attributes }
      bytes = images.map(&:download)
      writes = []
      subscriber = ->(*event) { writes << event.first }
      ActiveSupport::Notifications.subscribed(subscriber, %r{service_(upload|delete|delete_prefixed)\.active_storage}) do
        assert_no_difference ['ActiveStorage::Blob.count', 'ActiveStorage::Attachment.count'], &block
      end
      assert_empty writes unless allow_storage_writes
      assert_equal attributes, @reader.reload.attributes
      images = [@reader.avatar, @reader.avatar_thumbnail]
      assert_equal(attachments, images.map { |image| image.attachment.attributes })
      assert_equal(blobs, images.map { |image| image.blob.attributes })
      assert_equal bytes, images.map(&:download)
    end
  end
end
