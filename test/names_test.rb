# frozen_string_literal: true

require 'test_helper'
require 'bible270/names'

class NamesTest < Minitest::Test
  N = Bible270::Names

  def test_a_first_and_last_name_produce_the_display_name
    assert_equal({ first_name: 'Andrew', last_name: 'vonderLuft', display_name: 'Andrew vonderLuft' },
                 N.normalize('Andrew', 'vonderLuft'))
  end

  def test_internal_capitals_and_particles_survive
    assert_equal 'vonderLuft', N.normalize('Andrew', 'vonderLuft')[:last_name]
    assert_equal 'von der Luft', N.normalize('Andrew', 'von der Luft')[:last_name]
    assert_equal 'Mary Anne', N.normalize('Mary Anne', 'Smith')[:first_name]
  end

  def test_whitespace_is_squished_including_non_breaking_spaces
    assert_equal 'Andrew', N.squish("  Andrew\t ")
    assert_equal 'Andrew vonderLuft', N.squish("Andrew\u00A0 vonderLuft")
    assert_equal 'von der Luft', N.normalize('A', "von   der\tLuft")[:last_name]
  end

  def test_either_half_missing_is_rejected
    [['Andrew', ''], ['', 'vonderLuft'], [nil, nil], ['  ', ' '], ['Andrew', nil]].each do |first, last|
      assert_nil N.normalize(first, last), "#{[first, last].inspect} should be rejected"
      refute N.valid?(first, last)
    end
  end

  def test_splitting_a_display_name_keeps_the_surname_together
    assert_equal({ first_name: 'Andrew', last_name: 'von der Luft' }, N.split('Andrew von der Luft'))
    assert_equal({ first_name: 'Andrew', last_name: 'vonderLuft' }, N.split('Andrew vonderLuft'))
  end

  def test_a_single_word_cannot_be_split
    assert_nil N.split('Madonna')
    assert_nil N.split('')
    assert_nil N.split(nil)
  end
end

class NamesInitialTest < Minitest::Test
  N = Bible270::Names

  def test_the_surname_initial_follows_the_first_name
    assert_equal 'Mary Anne S.', N.first_with_last_initial('Mary Anne', 'Smith')
  end

  def test_particles_are_skipped_so_the_known_name_supplies_the_initial
    assert_equal 'Andrew L.', N.first_with_last_initial('Andrew', 'von der Luft')
  end

  def test_case_is_preserved_rather_than_upcased
    # A lowercase surname is usually deliberate; forcing "V." would override it.
    assert_equal 'Andrew v.', N.first_with_last_initial('Andrew', 'vonderLuft')
    assert_equal 'Andrew L.', N.first_with_last_initial('Andrew', 'Luft')
  end

  def test_whitespace_is_squished
    assert_equal 'andrew v.', N.first_with_last_initial('  andrew  ', ' vonderLuft ')
  end

  def test_a_missing_surname_leaves_just_the_first_name
    assert_equal 'Andrew', N.first_with_last_initial('Andrew', '')
    assert_equal 'Andrew', N.first_with_last_initial('Andrew', nil)
  end

  def test_normalize_returns_only_persisted_columns
    # This hash is assigned straight onto the model, so a derived key here would
    # raise NoMethodError for a column that doesn't exist.
    assert_equal %i[first_name last_name display_name], N.normalize('A', 'B').keys
  end
end
