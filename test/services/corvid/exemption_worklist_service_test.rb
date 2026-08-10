# frozen_string_literal: true

require "test_helper"

class Corvid::ExemptionWorklistServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_wl_test"

  setup do
    Corvid::TenantContext.current_tenant_identifier = TENANT
    @adapter = Corvid.adapter
  end

  test "flags an exempt member the state flagged for a work requirement" do
    assert_exemption("pt_a", "work_requirement")

    entries = Corvid::ExemptionWorklistService.at_risk([
      { person_identifier: "pt_a", requirement_type: "work_requirement",
        source: "state_271", flagged_on: Date.current }
    ])

    assert_equal 1, entries.size
    entry = entries.first
    assert_equal "pt_a", entry.person_identifier
    assert_equal "work_requirement", entry.requirement_type
    assert_equal "state_271", entry.source
    refute_nil entry.exemption_id
  end

  test "ignores state signals for members with no matching exemption" do
    # pt_b has a work_requirement exemption but the state flagged a
    # redetermination — different category, no matching exemption.
    assert_exemption("pt_b", "work_requirement")

    entries = Corvid::ExemptionWorklistService.at_risk([
      { person_identifier: "pt_b", requirement_type: "six_month_redetermination" },
      { person_identifier: "pt_nonexempt", requirement_type: "work_requirement" }
    ])

    assert_empty entries
  end

  test "ignores exemptions past expiry" do
    @adapter.add_ai_an_status("pt_c", ai_an: true, confidence: :verified)
    Corvid::MedicaidExemptionService.assert(
      person_identifier: "pt_c", exemption_types: [ "work_requirement" ],
      expires_at: 1.day.ago
    )

    entries = Corvid::ExemptionWorklistService.at_risk([
      { person_identifier: "pt_c", requirement_type: "work_requirement" }
    ])

    assert_empty entries
  end

  test "accepts signal objects, not just hashes" do
    assert_exemption("pt_d", "six_month_redetermination")
    signal = Struct.new(:person_identifier, :requirement_type, keyword_init: true)
      .new(person_identifier: "pt_d", requirement_type: "six_month_redetermination")

    entries = Corvid::ExemptionWorklistService.at_risk([ signal ])
    assert_equal 1, entries.size
  end

  private

  def assert_exemption(person, type)
    @adapter.add_ai_an_status(person, ai_an: true, confidence: :verified)
    Corvid::MedicaidExemptionService.assert(person_identifier: person, exemption_types: [ type ])
  end
end
