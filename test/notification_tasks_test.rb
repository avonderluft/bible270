# frozen_string_literal: true

require 'test_helper'
require 'rake'

if RAILS_LOADED
  Rake::Task.define_task(:environment) unless Rake::Task.task_defined?(:environment)
  load File.expand_path('../lib/tasks/bible270_notifications.rake', __dir__) unless
    Rake::Task.task_defined?('bible270:notifications:enable_all')

  class NotificationTasksTest < Minitest::Test
    def setup
      needs_rails!
      clear_engine_tables!
      create_reader('all@example.org', notify_on_mention: true, notify_on_all_comments: true)
      create_reader('personal@example.org', notify_on_mention: true, notify_on_all_comments: false)
      create_reader('none@example.org', notify_on_mention: false, notify_on_all_comments: false)
      task.reenable
    end

    def test_enable_all_updates_every_reader_and_is_idempotent
      output, = capture_io { task.invoke }

      assert_equal %w[all all all], Bible270::Reader.order(:email).map(&:comment_notification_level)
      assert_match(%r{Found 3 Bible270 readers in the test environment}, output)
      assert_match(%r{Updated 2 readers}, output)
      assert_match(%r{All 3 readers now receive every new reflection and reply}, output)

      task.reenable
      output, = capture_io { task.invoke }

      assert_match(%r{All 3 readers already receive every new reflection and reply}, output)
    end

    def test_enable_all_explains_an_empty_environment
      Bible270::Reader.delete_all
      task.reenable

      output, = capture_io { task.invoke }

      assert_match(%r{Found 0 Bible270 readers in the test environment}, output)
      assert_match(%r{No reader settings were changed}, output)
      assert_match(%r{Rerun with RAILS_ENV=production}, output)
      refute_match(%r{All 0 readers}, output)
    end

  private

    def task = Rake::Task['bible270:notifications:enable_all']

    def create_reader(email, preferences)
      Bible270::Reader.create!(
        { provider: 'email', uid: email, email: email, display_name: email }.merge(preferences)
      )
    end
  end
end
