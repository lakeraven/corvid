# frozen_string_literal: true

require "test_helper"

class Corvid::PriorAuthorizationApiServiceTest < ActiveSupport::TestCase
  TENANT = "tnt_pa"
  FACILITY = "fac_pa"

  def build_fhir_claim(overrides = {})
    {
      resourceType: "Claim",
      status: "active",
      use: "preauthorization",
      patient: { reference: "Patient/pt_pa_unit_001" },
      provider: { reference: "Practitioner/pr_pa_unit_001" },
      total: { value: 2500, currency: "USD" },
      item: [ { productOrService: "MRI" } ]
    }.merge(overrides)
  end

  test "submit_from_claim creates a Case and PrcReferral in submitted status" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = FACILITY
      response = Corvid::PriorAuthorizationApiService.submit_from_claim(build_fhir_claim)

      assert_equal "ClaimResponse", response[:resourceType]
      assert_equal "queued", response[:outcome]
      assert_equal "submitted", response[:disposition]

      referral = Corvid::PrcReferral.order(created_at: :desc).first
      assert_equal "submitted", referral.status
      assert_equal "pt_pa_unit_001", referral.case.patient_identifier
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "submit_from_claim scopes case lookup by facility" do
    with_tenant(TENANT) do
      Corvid::TenantContext.current_facility_identifier = "fac_a"
      Corvid::PriorAuthorizationApiService.submit_from_claim(build_fhir_claim)

      Corvid::TenantContext.current_facility_identifier = "fac_b"
      Corvid::PriorAuthorizationApiService.submit_from_claim(build_fhir_claim)

      cases = Corvid::Case.where(patient_identifier: "pt_pa_unit_001")
      facilities = cases.pluck(:facility_identifier).sort
      assert_equal [ "fac_a", "fac_b" ], facilities,
        "expected one Case per facility for the same patient"
    ensure
      Corvid::TenantContext.reset!
    end
  end

  test "claim_response_for maps authorized status to complete/approved" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_pa_unit_002", facility_identifier: FACILITY)
      referral = Corvid::PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_unit_authorized",
        facility_identifier: FACILITY,
        status: "authorized",
        authorization_number: "AUTH-UNIT-1"
      )

      response = Corvid::PriorAuthorizationApiService.claim_response_for(referral)
      assert_equal "complete", response[:outcome]
      assert_equal "approved", response[:disposition]
      assert_equal "AUTH-UNIT-1", response[:preAuthRef]
    end
  end

  test "claim_response_for includes denial reason when status is denied" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_pa_unit_003", facility_identifier: FACILITY)
      token = Corvid.adapter.store_text(
        case_token: kase.id.to_s, kind: :reason, text: "Service not medically necessary"
      )
      referral = Corvid::PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_unit_denied",
        facility_identifier: FACILITY,
        status: "denied",
        deferred_reason_token: token
      )
      referral.record_determination!(
        outcome: "denied",
        decision_method: "staff_review",
        determined_by_identifier: "pr_rev_001"
      )

      response = Corvid::PriorAuthorizationApiService.claim_response_for(referral)
      assert_equal "denied", response[:disposition]
      assert response[:processNote].any? { |n| n[:text] == "Service not medically necessary" }
    end
  end

  test "claim_response_for overrides disposition to pended for flagged-for-review" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_pa_unit_004", facility_identifier: FACILITY)
      referral = Corvid::PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_unit_flagged",
        facility_identifier: FACILITY,
        status: "submitted",
        flagged_for_review: true
      )

      response = Corvid::PriorAuthorizationApiService.claim_response_for(referral)
      assert_equal "pended", response[:disposition]
      assert response[:processNote].any? { |n| n[:type] == "display" },
        "expected a processNote carrying the info-request text"
    end
  end

  test "bundle_for_patient returns a searchset Bundle scoped to the patient" do
    with_tenant(TENANT) do
      kase = Corvid::Case.create!(patient_identifier: "pt_pa_unit_005", facility_identifier: FACILITY)
      Corvid::PrcReferral.create!(case: kase, referral_identifier: "rf_b1",
        facility_identifier: FACILITY, status: "authorized")
      Corvid::PrcReferral.create!(case: kase, referral_identifier: "rf_b2",
        facility_identifier: FACILITY, status: "denied")

      other_case = Corvid::Case.create!(patient_identifier: "pt_other", facility_identifier: FACILITY)
      Corvid::PrcReferral.create!(case: other_case, referral_identifier: "rf_other",
        facility_identifier: FACILITY, status: "authorized")

      bundle = Corvid::PriorAuthorizationApiService.bundle_for_patient("pt_pa_unit_005")
      assert_equal "Bundle", bundle[:resourceType]
      assert_equal "searchset", bundle[:type]
      assert_equal 2, bundle[:entry].size
      ids = bundle[:entry].map { |e| e[:resource][:id] }.sort
      assert_equal [ "rf_b1", "rf_b2" ], ids
    end
  end

  test "covered_services returns a Bundle of ActivityDefinitions" do
    result = Corvid::PriorAuthorizationApiService.covered_services
    assert_equal "Bundle", result[:resourceType]
    assert result[:entry].all? { |e| e[:resource][:resourceType] == "ActivityDefinition" }
  end

  test "documentation_requirements_for returns a Questionnaire with required items" do
    q = Corvid::PriorAuthorizationApiService.documentation_requirements_for("MRI")
    assert_equal "Questionnaire", q[:resourceType]
    assert q[:item].any? { |i| i[:required] }
  end
end
