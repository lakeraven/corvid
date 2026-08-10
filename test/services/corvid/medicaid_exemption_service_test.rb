# frozen_string_literal: true

require "test_helper"

# Exercises the assert contract: verified AI/AN status → exemption(s) +
# :asserted event, all fail-closed (no self-report, no fabricated positive).
class Corvid::MedicaidExemptionServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_svc_test"

  setup do
    Corvid::TenantContext.current_tenant_identifier = TENANT
    @adapter = Corvid.adapter
  end

  # -- Verified positive -----------------------------------------------------

  test "asserts both HR-1 exemptions from verified AI/AN status" do
    @adapter.add_ai_an_status("pt_v", ai_an: true, ihs_beneficiary: true,
                              basis: "ai_an_ihs_beneficiary", confidence: :verified)

    result = Corvid::MedicaidExemptionService.assert(
      person_identifier: "pt_v", asserted_by_identifier: "usr_1"
    )

    assert result.asserted?
    assert_equal :asserted, result.reason
    assert_equal 2, result.exemption_ids.size

    types = Corvid::MedicaidExemption.for_person("pt_v").active.pluck(:exemption_type).sort
    assert_equal %w[six_month_redetermination work_requirement], types
  end

  test "records an :asserted event per exemption with provenance on the row" do
    @adapter.add_ai_an_status("pt_v", ai_an: true, confidence: :verified)

    Corvid::MedicaidExemptionService.assert(
      person_identifier: "pt_v", exemption_types: [ "work_requirement" ],
      asserted_by_identifier: "usr_1"
    )

    exemption = Corvid::MedicaidExemption.for_person("pt_v").active.first
    assert_equal "Corvid::Adapters::MockAdapter", exemption.verification_source
    assert_equal "verified", exemption.verification_confidence
    refute_nil exemption.verification_snapshot_hash
    refute_nil exemption.verified_at

    events = Corvid::ExemptionEvent.for_person("pt_v").of_type("asserted")
    assert_equal 1, events.count
  end

  # -- Re-assert refreshes, does not duplicate -------------------------------

  test "re-asserting refreshes the same exemption row" do
    @adapter.add_ai_an_status("pt_v", ai_an: true, confidence: :verified)

    Corvid::MedicaidExemptionService.assert(person_identifier: "pt_v", exemption_types: [ "work_requirement" ])
    assert_no_difference "Corvid::MedicaidExemption.count" do
      Corvid::MedicaidExemptionService.assert(person_identifier: "pt_v", exemption_types: [ "work_requirement" ])
    end
  end

  # -- Fail-closed: unavailable source ---------------------------------------

  test "does not assert when the verification source is unavailable" do
    @adapter.add_ai_an_status("pt_u", ai_an: true, confidence: :unavailable)

    result = Corvid::MedicaidExemptionService.assert(person_identifier: "pt_u")

    refute result.asserted?
    assert_equal :verification_unavailable, result.reason
    assert_equal 0, Corvid::MedicaidExemption.for_person("pt_u").count
  end

  # -- Fail-closed: not AI/AN ------------------------------------------------

  test "does not assert when the person is not AI/AN" do
    @adapter.add_ai_an_status("pt_n", ai_an: false, ihs_beneficiary: false, confidence: :verified)

    result = Corvid::MedicaidExemptionService.assert(person_identifier: "pt_n")

    refute result.asserted?
    assert_equal :not_ai_an, result.reason
    assert_equal 0, Corvid::MedicaidExemption.for_person("pt_n").count
  end

  test "unknown person (no status record) is a verified negative, not asserted" do
    result = Corvid::MedicaidExemptionService.assert(person_identifier: "pt_unknown")
    refute result.asserted?
    assert_equal :not_ai_an, result.reason
  end

  # -- Deterministic snapshot hash -------------------------------------------

  test "identical verified status yields an identical snapshot hash" do
    @adapter.add_ai_an_status("pt_h", ai_an: true, ihs_beneficiary: true,
                              basis: "ai_an_ihs_beneficiary", confidence: :verified)

    Corvid::MedicaidExemptionService.assert(person_identifier: "pt_h", exemption_types: [ "work_requirement" ])
    first = Corvid::MedicaidExemption.for_person("pt_h").active.first.verification_snapshot_hash
    Corvid::MedicaidExemptionService.assert(person_identifier: "pt_h", exemption_types: [ "work_requirement" ])
    second = Corvid::MedicaidExemption.for_person("pt_h").active.first.verification_snapshot_hash

    assert_equal first, second
  end

  # -- Outcome events --------------------------------------------------------

  test "record_outcome writes a life-outcome event" do
    @adapter.add_ai_an_status("pt_o", ai_an: true, confidence: :verified)
    Corvid::MedicaidExemptionService.assert(person_identifier: "pt_o", exemption_types: [ "work_requirement" ])
    exemption = Corvid::MedicaidExemption.for_person("pt_o").active.first

    event = Corvid::MedicaidExemptionService.record_outcome(
      person_identifier: "pt_o",
      event_type: "erroneously_disenrolled",
      exemption: exemption,
      recorded_by_identifier: "usr_2"
    )

    assert event.persisted?
    assert event.event_erroneously_disenrolled?
    assert_equal "work_requirement", event.exemption_type
  end
end
