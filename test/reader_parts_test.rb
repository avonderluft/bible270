# frozen_string_literal: true

require 'test_helper'

# Per-chapter check-offs. Skips entirely until the `part` column and the Plan
# part methods exist.
class ReaderPartsTest < Minitest::Test
  def setup
    needs_chapter_parts!
    clear_engine_tables!
    @reader = Bible270::Reader.create!(provider: 'email', uid: 'p@example.org',
                                       email: 'p@example.org', display_name: 'Parts Reader')
  end

  # Day 1 is Genesis 1-3 plus Matthew 1 plus Psalm 1: five boxes, not three.
  def test_a_day_is_complete_only_when_every_chapter_is_ticked
    assert_equal 5, Bible270::Plan.total_parts(1)

    Bible270::Plan.parts_for(1, 'ot').each_index do |part|
      @reader.checkoffs.create!(day: 1, track: 'ot', part: part)
    end
    @reader.reload_progress
    refute @reader.day_complete?(1), 'the other two tracks are still unread'

    @reader.checkoffs.create!(day: 1, track: 'nt', part: 0)
    @reader.checkoffs.create!(day: 1, track: 'pp', part: 0)
    @reader.reload_progress

    assert @reader.day_complete?(1)
  end

  def test_a_track_is_read_only_when_all_its_chapters_are
    @reader.checkoffs.create!(day: 1, track: 'ot', part: 0)

    refute @reader.read?(1, 'ot')
    assert @reader.read?(1, 'ot', 0)
    assert @reader.track_partially_read?(1, 'ot')

    [1, 2].each { |part| @reader.checkoffs.create!(day: 1, track: 'ot', part: part) }
    @reader.reload_progress

    assert @reader.read?(1, 'ot')
    refute @reader.track_partially_read?(1, 'ot')
  end

  def test_days_read_in_counts_finished_days_not_chapters
    @reader.mark_day_complete!(1)
    @reader.checkoffs.create!(day: 2, track: 'ot', part: 0)
    @reader.reload_progress

    assert_equal 1, @reader.days_read_in('ot'),
                 'a part-read day should not count, and chapters are not days'
  end

  def test_the_same_chapter_cannot_be_ticked_twice
    @reader.checkoffs.create!(day: 1, track: 'ot', part: 0)

    duplicate = @reader.checkoffs.build(day: 1, track: 'ot', part: 0)
    refute duplicate.valid?
  end

  def test_a_part_outside_the_reading_is_refused
    beyond = @reader.checkoffs.build(day: 1, track: 'ot', part: 99)
    refute beyond.valid?

    single_chapter = @reader.checkoffs.build(day: 1, track: 'nt', part: 1)
    refute single_chapter.valid?, 'a one-chapter reading has only part 0'
  end
end
