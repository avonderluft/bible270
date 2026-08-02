# frozen_string_literal: true

require 'test_helper'
require 'bible270/configuration'
require 'bible270/avatars'

class AvatarsTest < Minitest::Test
  A = Bible270::Avatars

  def setup
    @previous = Bible270.config.avatar_max_bytes
  end

  def teardown
    Bible270.config.avatar_max_bytes = @previous
  end

  def test_the_expected_image_types_are_accepted
    %w[image/png image/jpeg image/gif image/webp].each do |type|
      assert A.acceptable_type?(type), "#{type} should be accepted"
    end
  end

  def test_other_types_are_rejected
    # SVG in particular: it can carry script, and it isn't worth the risk for an
    # avatar.
    %w[image/svg+xml text/html application/pdf image/tiff].each do |type|
      refute A.acceptable_type?(type), "#{type} should be rejected"
    end
  end

  def test_type_matching_ignores_case_and_parameters
    assert A.acceptable_type?('IMAGE/JPEG')
    assert A.acceptable_type?('image/png; charset=binary')
    assert A.acceptable_type?(' image/webp ')
  end

  def test_size_limits
    assert A.acceptable_size?(1)
    assert A.acceptable_size?(A.max_bytes)
    refute A.acceptable_size?(A.max_bytes + 1)
    refute A.acceptable_size?(0)
  end

  def test_the_limit_is_configurable
    Bible270.config.avatar_max_bytes = 1024
    assert A.acceptable_size?(1024)
    refute A.acceptable_size?(1025)
  end

  def test_a_zero_or_absent_limit_falls_back_to_the_default
    Bible270.config.avatar_max_bytes = 0
    assert_equal A::DEFAULT_MAX_BYTES, A.max_bytes
  end

  def test_problem_with_names_the_reason_or_returns_nil
    assert_nil A.problem_with(content_type: 'image/png', byte_size: 1000)
    assert_match(%r{PNG, JPEG, GIF or WebP}, A.problem_with(content_type: 'image/svg+xml', byte_size: 10))
    assert_match(%r{empty}, A.problem_with(content_type: 'image/png', byte_size: 0))
    assert_match(%r{under 2MB}, A.problem_with(content_type: 'image/png', byte_size: 5 * 1024 * 1024))
  end

  def test_human_size
    assert_equal '2MB', A.human_size(2 * 1024 * 1024)
    assert_equal '1.5MB', A.human_size(1.5 * 1024 * 1024)
    assert_equal '500KB', A.human_size(512_000)
  end
end

class AvatarsContentTypesTest < Minitest::Test
  def test_content_types_is_the_accepted_list
    assert_equal Bible270::Avatars::CONTENT_TYPES, Bible270::Avatars.content_types
    assert(Bible270::Avatars.content_types.all? { |t| t.start_with?('image/') })
  end
end
