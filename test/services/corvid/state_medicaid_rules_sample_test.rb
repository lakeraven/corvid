# frozen_string_literal: true

require "test_helper"

class Corvid::StateMedicaidRulesSampleTest < ActiveSupport::TestCase
  test "dummy app registers synthetic state XA with expansion adult and other groups" do
    entry = Corvid::StateMedicaidRules.lookup("XA")
    assert entry.configured?
    assert_equal "XA", entry.state_code
    assert entry.expanded?

    expansion = entry.group("expansion_adult")
    refute_nil expansion
    assert_equal 12, expansion.renewal_months
    assert_equal 3, expansion.retro_coverage_months
    refute expansion.work_requirement?

    other = entry.group("other")
    refute_nil other
    assert_equal 24, other.renewal_months
    assert_equal 1, other.retro_coverage_months
    refute other.work_requirement?

    assert_nil entry.group("waiver_adult")
    assert_equal [], entry.work_requirement_programs
  end

  test "dummy app registers synthetic state XB with waiver program and waiver adult group" do
    entry = Corvid::StateMedicaidRules.lookup("XB")
    assert entry.configured?
    assert_equal "XB", entry.state_code
    refute entry.expanded?

    waiver_adult = entry.group("waiver_adult")
    refute_nil waiver_adult
    assert_equal 12, waiver_adult.renewal_months
    assert_equal 2, waiver_adult.retro_coverage_months
    assert waiver_adult.work_requirement?

    program = entry.work_requirement_programs.first
    refute_nil program
    assert_equal "xb_synthetic_waiver", program.code
    assert_equal(/\bTEST SYNTHETIC WAIVER\b/i, program.description_pattern)

    matched = entry.waiver_program_for("Plan includes TEST SYNTHETIC WAIVER option")
    refute_nil matched
    assert_equal "xb_synthetic_waiver", matched.code
  end

  test "unregistered real-looking state code returns NotConfigured" do
    result = Corvid::StateMedicaidRules.lookup("CA")
    assert_kind_of Corvid::StateMedicaidRules::NotConfigured, result
    refute result.configured?
    assert_equal "CA", result.state_code
  end

  test "registered synthetic codes appear in state_codes" do
    codes = Corvid::StateMedicaidRules.state_codes
    assert_includes codes, "XA"
    assert_includes codes, "XB"
  end
end
