# frozen_string_literal: true

require 'test_helper'

# The riskiest code in the gem: it rewrites readers' progress in place. Getting
# it wrong silently demotes a finished multi-chapter day to one chapter of it,
# and nobody would notice until they looked at their own history.
#
# The migration has already run by the time tests start, so this exercises the
# backfill directly against rows shaped the way the old schema left them.
if RAILS_LOADED
  require Dir.glob(File.expand_path('../db/migrate/*_add_part_to_bible270_checkoffs.rb', __dir__)).first

  class CheckoffBackfillTest < Minitest::Test
    def setup
      needs_chapter_parts!
      clear_engine_tables!
      @reader = Bible270::Reader.create!(provider: 'email', uid: 'b@example.org',
                                         email: 'b@example.org', display_name: 'Backfill Reader')
      @migration = AddPartToBible270Checkoffs.new
      @migration.verbose = false
    end

    # One row per track is what the old schema stored, and it meant "the whole
    # reading is done".
    def legacy_checkoff(day, track)
      Bible270::Checkoff.insert_all([{ reader_id: @reader.id, day: day, track: track, part: 0,
                                       created_at: Time.current, updated_at: Time.current }])
    end

    def expand!
      @migration.send(:expand_existing_checkoffs)
      @reader.reload_progress
    end

    def test_a_finished_multi_chapter_day_keeps_its_completion
      Bible270::Plan.present_tracks(1).each { |track| legacy_checkoff(1, track) }
      assert_equal 3, @reader.checkoffs.count, 'three rows, as the old schema stored'
      refute @reader.day_complete?(1), 'three rows is not five boxes'

      expand!

      assert_equal Bible270::Plan.total_parts(1), @reader.checkoffs.where(day: 1).count
      assert @reader.day_complete?(1), 'a day that was finished must stay finished'
    end

    def test_it_fills_in_every_chapter_of_the_reading
      legacy_checkoff(1, 'ot')
      expand!

      assert_equal [0, 1, 2], @reader.checkoffs.where(day: 1, track: 'ot').order(:part).pluck(:part)
    end

    def test_single_chapter_readings_are_left_alone
      legacy_checkoff(1, 'nt')
      expand!

      assert_equal [0], @reader.checkoffs.where(day: 1, track: 'nt').pluck(:part)
    end

    def test_a_partly_read_day_is_not_promoted
      legacy_checkoff(1, 'nt')
      expand!

      refute @reader.day_complete?(1), 'only the New Testament was read'
    end

    def test_running_it_twice_changes_nothing
      Bible270::Plan.present_tracks(1).each { |track| legacy_checkoff(1, track) }
      expand!
      before = @reader.checkoffs.count

      expand!

      assert_equal before, @reader.checkoffs.count, 'the backfill must be idempotent'
    end

    def test_nothing_to_do_is_harmless
      expand! # no check-offs at all

      assert_equal 0, Bible270::Checkoff.count
    end

    def test_it_covers_the_longest_reading_in_the_plan
      # Day 270 is Zechariah 14 plus Malachi 1-4: five chapters.
      legacy_checkoff(270, 'ot')
      expand!

      assert_equal Bible270::Plan.part_count(270, 'ot'),
                   @reader.checkoffs.where(day: 270, track: 'ot').count
    end
  end
end
