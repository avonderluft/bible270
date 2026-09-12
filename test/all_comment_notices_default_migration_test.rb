# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  require Dir.glob(File.expand_path('../db/migrate/*_change_all_comment_notices_default_to_true.rb', __dir__)).first

  class AllCommentNoticesDefaultMigrationTest < Minitest::Test
    class IsolatedRecord < ActiveRecord::Base
      self.abstract_class = true
    end

    class IsolatedReader < IsolatedRecord
      self.table_name = 'bible270_readers'
    end

    def setup
      IsolatedRecord.establish_connection(adapter: 'sqlite3', database: ':memory:')
      @connection = IsolatedRecord.connection
      @connection.create_table(:bible270_readers) do |table|
        table.string :display_name, null: false
        table.boolean :notify_on_all_comments, null: false, default: false
      end
      @existing = IsolatedReader.create!(display_name: 'Existing reader')
      @migration = ChangeAllCommentNoticesDefaultToTrue.new
      @migration.verbose = false
      connection = @connection
      @migration.define_singleton_method(:connection) { connection }
    end

    def teardown
      IsolatedRecord.connection_pool.disconnect!
    end

    def test_only_new_readers_receive_the_new_default
      @migration.up
      IsolatedReader.reset_column_information
      new_reader = IsolatedReader.create!(display_name: 'New reader')

      refute @existing.reload.notify_on_all_comments
      assert new_reader.notify_on_all_comments
      assert boolean_default
    end

    def test_the_previous_default_can_be_restored
      @migration.up
      @migration.down
      IsolatedReader.reset_column_information
      new_reader = IsolatedReader.create!(display_name: 'New reader')

      refute new_reader.notify_on_all_comments
      refute boolean_default
    end

  private

    def boolean_default
      column = @connection.columns(:bible270_readers).find { |candidate| candidate.name == 'notify_on_all_comments' }
      ActiveModel::Type::Boolean.new.cast(column.default)
    end
  end
end
