# frozen_string_literal: true

require "minitest/autorun"
require "corvid/version"

class CorvidTest < Minitest::Test
  def test_version_is_defined
    refute_nil Corvid::VERSION
    assert_match(/\A\d+\.\d+\.\d+/, Corvid::VERSION)
  end

  def test_initial_version_is_0_1_0
    assert_equal "0.1.0", Corvid::VERSION
  end
end
