# frozen_string_literal: true

require 'test_helper'
require 'bible270/mentions'

class MentionsTest < Minitest::Test
  M = Bible270::Mentions

  def test_it_finds_a_mention
    assert_equal ['andrew'], M.extract('Thanks @Andrew for this')
  end

  def test_it_finds_several_and_de_duplicates
    assert_equal %w[andrew mary], M.extract('@Andrew and @Mary and @andrew again')
  end

  def test_it_accepts_the_dotted_form
    assert_equal ['andrew.vonderluft'], M.extract('@Andrew.vonderLuft what do you think?')
  end

  # Sentence punctuation must not become part of the handle.
  def test_trailing_punctuation_is_dropped
    assert_equal ['andrew'], M.extract('I agree with @Andrew.')
    assert_equal ['andrew'], M.extract('@Andrew, yes')
    assert_equal ['andrew'], M.extract('(@Andrew)')
  end

  # An address in the body would otherwise read as a mention of the domain.
  def test_an_email_address_is_not_a_mention
    assert_empty M.extract('write to andrew@example.org')
  end

  def test_a_bare_at_sign_is_not_a_mention
    assert_empty M.extract('meet @ 7pm')
    assert_empty M.extract('@')
  end

  def test_nothing_in_nothing_out
    assert_empty M.extract(nil)
    assert_empty M.extract('')
    assert_empty M.extract('no mentions here')
  end

  def test_names_with_apostrophes_and_hyphens_survive
    assert_equal ["o'brien"], M.extract("@O'Brien said so")
    assert_equal ['mary-anne'], M.extract('@Mary-Anne said so')
  end

  def test_accented_names_are_kept
    assert_equal ['józef'], M.extract('@Józef wrote that')
  end

  # A reflection full of mentions would become a way to mail everyone at once.
  def test_the_number_of_mentions_is_capped
    body = (1..20).map { |n| "@person#{n}" }.join(' ')

    assert_equal M::MAX_PER_COMMENT, M.extract(body).size
  end

  def test_handles_for_a_reader
    assert_equal %w[andrew andrew.vonderluft], M.handles_for('Andrew', 'vonderLuft')
    assert_equal ['madonna'], M.handles_for('Madonna', nil)
    assert_empty M.handles_for('', 'vonderLuft')
  end

  def test_highlighting_leaves_the_rest_of_the_text_alone
    result = M.highlight('Yes @Andrew, quite so') { |handle, text| "[#{handle}|#{text}]" }

    assert_equal 'Yes [andrew|@Andrew], quite so', result
  end

  def test_highlighting_handles_no_mentions_and_nil
    assert_equal 'nothing here', M.highlight('nothing here') { |_h, t| t }
    assert_equal '', M.highlight(nil) { |_h, t| t }
  end
end
