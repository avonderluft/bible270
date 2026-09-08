# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  require Dir.glob(File.expand_path('../db/migrate/*_add_body_format_to_bible270_comments.rb', __dir__)).first

  class BodyFormatMigrationTest < Minitest::Test
    class IsolatedRecord < ActiveRecord::Base
      self.abstract_class = true
    end

    def setup
      IsolatedRecord.establish_connection(adapter: 'sqlite3', database: ':memory:')
      @connection = IsolatedRecord.connection
      @connection.create_table(:bible270_comments) { |table| table.text :body, null: false }
      @connection.execute("INSERT INTO bible270_comments (body) VALUES ('Old **literal** body')")
      @migration = AddBodyFormatToBible270Comments.new
      @migration.verbose = false
      connection = @connection
      @migration.define_singleton_method(:connection) { connection }
    end

    def teardown
      IsolatedRecord.connection_pool.disconnect!
    end

    def test_existing_and_new_rows_default_to_plain_text
      @migration.up
      @connection.execute("INSERT INTO bible270_comments (body) VALUES ('New body')")
      column = @connection.columns(:bible270_comments).find { |candidate| candidate.name == 'body_format' }

      assert_equal 'plain', column.default
      refute column.null
      assert_equal %w[plain plain], @connection.select_values(
        'SELECT body_format FROM bible270_comments ORDER BY id'
      )
      assert_equal ['Old **literal** body', 'New body'], @connection.select_values(
        'SELECT body FROM bible270_comments ORDER BY id'
      )
    end

    def test_the_migration_is_reversible_without_removing_bodies
      @migration.up
      @migration.down

      refute @connection.column_exists?(:bible270_comments, :body_format)
      assert_equal ['Old **literal** body'], @connection.select_values('SELECT body FROM bible270_comments')
    end
  end
end
