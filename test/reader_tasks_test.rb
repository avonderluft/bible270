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

      assert_equal <<~TABLE, output
        Name             Days Read  Status
        ---------------  ---------  -------------
        Ahead Reader            12  2 days ahead
        On Track Reader         10  on track
        Undated Reader           9  undated
        Behind Reader            7  3 days behind
      TABLE
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
