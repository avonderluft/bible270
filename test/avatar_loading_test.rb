# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  class AvatarLoadingTest < ActionDispatch::IntegrationTest
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_admins = Bible270.config.admin_emails
      @previous_notices = Bible270.config.mention_notifications
      Bible270.config.mention_notifications = false
      @readers = 6.times.map do |number|
        reader = Bible270::Reader.create!(display_name: "Reader #{number}",
                                          provider: 'email', uid: "avatar#{number}@example.org",
                                          email: "avatar#{number}@example.org")
        if Bible270::Reader.avatar_uploads? && number.positive?
          reader.avatar.attach(io: StringIO.new('picture'), filename: 'picture.png', content_type: 'image/png')
        end
        reader.mark_day_complete!(1)
        reader
      end
      @readers.each_with_index do |reader, index|
        comment = reader.comments.create!(day: 1, body: 'A reflection')
        comment.replies.create!(reader: @readers[(index + 1) % @readers.size], day: 1, body: 'A reply')
      end
    end

    def teardown
      Bible270.config.admin_emails = @previous_admins
      Bible270.config.mention_notifications = @previous_notices
    end

    def mount = Bible270.config.mount_at.chomp('/')

    def test_reader_and_thread_preloads_need_no_queries_to_read_avatars
      skip 'Active Storage unavailable' unless Bible270::Reader.avatar_uploads?

      readers = Bible270::Reader.with_avatar.to_a
      completers = Bible270::Reader.completers_for(1)
      threads = Bible270::Comment.threads_for_day(1).to_a
      paged_threads = Bible270::Comment.thread_page.threads
      comments = (threads + paged_threads).flat_map { |thread| [thread, *thread.visible_replies] }
      assert_equal @readers.size, completers.size
      queries = avatar_queries do
        (readers + completers + comments.map(&:reader)).each do |reader|
          assert reader.association(:avatar_attachment).loaded?
          next unless reader.avatar_uploaded?

          assert reader.avatar_attachment.association(:blob).loaded?
          assert_equal 'picture.png', reader.avatar.blob.filename.to_s
        end
      end
      assert_empty queries
    end

    def test_reader_heavy_pages_use_bounded_avatar_queries
      skip 'Active Storage unavailable' unless Bible270::Reader.avatar_uploads?

      { '/community' => 2, '/day/1' => 6, '/reflections' => 4,
        "/readers/#{@readers.first.id}" => 5 }.each do |path, limit|
        assert_page_avatar_queries(path, limit)
      end

      admin = @readers[1]
      Bible270.config.admin_emails = [admin.email]
      _record, token = Bible270::SignInToken.issue!(admin.email)
      get "#{mount}/sign_in/email/#{token}"
      { '/admin' => 2, '/admin/comments' => 2, '/progress' => 4 }.each do |path, limit|
        assert_page_avatar_queries(path, limit)
      end
    end

    def test_preload_scopes_still_work_without_avatar_uploads
      Bible270::Reader.stub(:avatar_uploads?, false) do
        assert_empty Bible270::Reader.with_avatar.includes_values
        assert_equal @readers.size, Bible270::Reader.with_avatar.count
        threads = Bible270::Comment.threads_for_day(1).to_a
        assert_equal @readers.size, threads.size
        threads.each do |thread|
          assert thread.association(:reader).loaded?
          assert thread.association(:replies).loaded?
          refute thread.reader.association(:avatar_attachment).loaded? if Bible270::Reader::AVATAR_UPLOADS
        end
      end
    end

  private

    def assert_page_avatar_queries(path, limit)
      queries = avatar_queries { get "#{mount}#{path}" }
      assert_response :success
      assert_operator queries.size, :<=, limit, "#{path} made too many avatar queries:\n#{queries.join("\n")}"
      assert_select 'img.b270-avatar[loading="lazy"][decoding="async"]'
    end

    def avatar_queries(&block)
      queries = []
      subscriber = ->(_name, _start, _finish, _id, payload) do
        next if payload[:name] == 'SCHEMA'
        next unless payload[:sql].match?(%r{\bSELECT\b.*\bactive_storage_(?:attachments|blobs)\b}i)

        queries << payload[:sql]
      end
      ActiveRecord::Base.uncached do
        ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &block)
      end
      queries
    end
  end
end
