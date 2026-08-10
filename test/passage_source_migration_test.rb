# frozen_string_literal: true

require 'test_helper'

if RAILS_LOADED
  require Dir.glob(File.expand_path('../db/migrate/*_add_passage_source_to_bible270_readers.rb', __dir__)).first

  class PassageSourceMigrationTest < Minitest::Test
    class IsolatedRecord < ActiveRecord::Base
      self.abstract_class = true
    end

    def setup
      IsolatedRecord.establish_connection(adapter: 'sqlite3', database: ':memory:')
      @connection = IsolatedRecord.connection
      @migration = AddPassageSourceToBible270Readers.new
      @migration.verbose = false
      connection = @connection
      @migration.define_singleton_method(:connection) { connection }
    end

    def teardown
      IsolatedRecord.connection_pool.disconnect!
    end

    def test_up_converts_both_legacy_boolean_values
      create_legacy_table
      @connection.execute <<~SQL.squish
        INSERT INTO bible270_readers (blue_letter_bible)
        VALUES (FALSE), (TRUE)
      SQL

      @migration.up

      assert_equal %w[bible_gateway blue_letter_bible], passage_sources
      assert_column 'passage_source'
      refute_column 'blue_letter_bible'
    end

    def test_up_adds_a_non_null_bible_gateway_default
      create_readers_table

      @migration.up
      @connection.execute('INSERT INTO bible270_readers DEFAULT VALUES')

      column = @connection.columns(:bible270_readers).find { |candidate| candidate.name == 'passage_source' }
      assert_equal 'bible_gateway', column.default
      refute column.null
      assert_equal ['bible_gateway'], passage_sources
    end

    def test_down_preserves_each_source_in_the_legacy_boolean
      create_readers_table do |table|
        table.string :passage_source, default: 'bible_gateway', null: false
      end
      @connection.execute <<~SQL.squish
        INSERT INTO bible270_readers (passage_source)
        VALUES ('bible_gateway'), ('blue_letter_bible')
      SQL

      @migration.down

      legacy_values = @connection.select_values(<<~SQL.squish).map { |value| value == 1 }
        SELECT blue_letter_bible FROM bible270_readers ORDER BY id
      SQL
      assert_equal [false, true], legacy_values
      assert_column 'blue_letter_bible'
      refute_column 'passage_source'
    end

  private

    def create_legacy_table
      create_readers_table do |table|
        table.boolean :blue_letter_bible, default: false, null: false
      end
    end

    def create_readers_table(&)
      @connection.create_table(:bible270_readers, &)
    end

    def passage_sources
      @connection.select_values('SELECT passage_source FROM bible270_readers ORDER BY id')
    end

    def assert_column(name)
      assert @connection.column_exists?(:bible270_readers, name), "expected column #{name}"
    end

    def refute_column(name)
      refute @connection.column_exists?(:bible270_readers, name), "did not expect column #{name}"
    end
  end
end
