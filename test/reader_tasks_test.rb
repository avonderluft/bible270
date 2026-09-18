# frozen_string_literal: true

require 'test_helper'
require 'rake'

if RAILS_LOADED
  Rake::Task.define_task(:environment) unless Rake::Task.task_defined?(:environment)
  load File.expand_path('../lib/tasks/bible270_readers.rake', __dir__) unless
    Rake::Task.task_defined?('bible270:readers:list')

  class ReaderTasksTest < Minitest::Test
    def setup
      needs_rails!
      clear_engine_tables!
      @previous_start_date = Bible270.config.start_date
      @previous_personal_dates = Bible270.config.allow_reader_start_date
      Bible270.config.start_date = nil
      Bible270.config.allow_reader_start_date = true
      create_reader('Ahead Reader', days: 12, started_on: Bible270.today - 9)
      create_reader('On Track Reader', days: 10, started_on: Bible270.today - 9)
      create_reader('Undated Reader', days: 9)
      create_reader('Behind Reader', days: 7, started_on: Bible270.today - 9)
      task.reenable
    end

    def teardown
      Bible270.config.start_date = @previous_start_date
      Bible270.config.allow_reader_start_date = @previous_personal_dates
    end

    def test_list_prints_aligned_columns_in_descending_days_read_order
      output, = capture_io { task.invoke }
      last_activity = Bible270.today.strftime('%b %-d, %Y')

      assert_equal <<~TABLE, output
        Name             Days Read  Status         Last Activity
        ---------------  ---------  -------------  -------------
        Ahead Reader            12  2 days ahead   #{last_activity}
        On Track Reader         10  on track       #{last_activity}
        Undated Reader           9  undated        #{last_activity}
        Behind Reader            7  3 days behind  #{last_activity}
      TABLE
    end

    def test_list_marks_readers_without_activity
      Bible270::Checkoff.delete_all
      task.reenable

      output, = capture_io { task.invoke }
      readers_without_activity = output.lines.count { |line| line.end_with?("—\n") }

      assert_equal 4, readers_without_activity
    end

    def test_list_explains_an_empty_environment
      Bible270::Checkoff.delete_all
      Bible270::Reader.delete_all
      task.reenable

      output, = capture_io { task.invoke }

      assert_equal "No Bible270 readers found in the test environment.\n", output
    end

  private

    def task = Rake::Task['bible270:readers:list']

    def create_reader(name, days:, started_on: nil)
      email = "#{name.parameterize}@example.org"
      reader = Bible270::Reader.create!(provider: 'email', uid: email, email: email, display_name: name,
                                        started_on: started_on)
      reader.mark_through!(days)
    end
  end
end
