# frozen_string_literal: true

require 'test_helper'
require 'bible270/versification'

# The verse counts underpin every division in the plan: a wrong number silently
# shifts break points and reading lengths, and nothing else would notice.
class VersificationTest < Minitest::Test
  V = Bible270::Versification

  def test_the_canon_is_complete
    assert_equal 1189, V::VERSES.values.sum(&:size), 'the Protestant canon has 1,189 chapters'
    assert_equal 66, V::VERSES.size, 'and 66 books'
  end

  def test_landmark_chapter_counts
    { 'Genesis' => 50, 'Psalm' => 150, 'Proverbs' => 31, 'Matthew' => 28,
      'Revelation' => 22, 'Obadiah' => 1, 'Malachi' => 4 }.each do |book, chapters|
      assert_equal chapters, V.chapter_count(book), book
    end
  end

  def test_landmark_verse_counts
    assert_equal 176, V.verses('Psalm', 119), 'the longest chapter'
    assert_equal 2,   V.verses('Psalm', 117), 'the shortest'
    assert_equal 31,  V.verses('Genesis', 1)
    assert_equal 21,  V.verses('Revelation', 22)
  end

  def test_book_totals
    assert_equal(2461, (1..150).sum { |c| V.verses('Psalm', c) })
    assert_equal(915,  (1..31).sum { |c| V.verses('Proverbs', c) })
  end

  def test_every_chapter_has_a_positive_verse_count
    offenders = V::VERSES.flat_map do |book, counts|
      counts.each_with_index.filter_map { |n, i| "#{book} #{i + 1} = #{n.inspect}" unless n.is_a?(Integer) && n.positive? }
    end
    assert_empty offenders
  end

  # Chapter 0 used to become index -1 and return Genesis 50's verse count.
  def test_chapters_outside_a_book_count_as_nothing
    assert_equal 0, V.verses('Genesis', 0)
    assert_equal 0, V.verses('Genesis', 51)
    assert_equal 0, V.verses('Genesis', -1)
    assert_equal 0, V.verses('Genesis', nil)
  end

  # An unknown book is a mistake in the caller, not bad input, so it stays loud.
  def test_an_unknown_book_raises
    assert_raises(KeyError) { V.verses('Hezekiah', 1) }
    assert_raises(KeyError) { V.chapter_count('Hezekiah') }
  end
end
