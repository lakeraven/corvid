# frozen_string_literal: true

require "test_helper"

# Review finding (PR #598, medium, DISPUTED — see corvid#598 review table):
# "Require verified AI/AN status for federal coverage" claimed the classifier
# must gate the 100% federal share on verified AI/AN beneficiary status,
# since an unknown/non-AI/AN patient at a matching facility still gets
# federal_percent: 100.
#
# That is the intended behavior, not a bug: SSA Sec. 1905(b) — quoted
# verbatim in features/billing/medicaid_referral_billing.feature's header —
# grants 100% FMAP for "medical assistance for services received through"
# an IHS or tribal facility. The statute is FACILITY-based, not a
# beneficiary-identity test; gating it on AI/AN status would reintroduce
# exactly the "Indian status" framing this codebase deliberately avoids
# elsewhere (see MEMORY: "'Service eligibility', never 'Indian status'").
# ai_an_beneficiary_basis is an informational audit tag, never a gate.
# This test pins the current (correct) behavior down so it isn't
# "fixed" into a statutory error later.
class Corvid::MedicaidFederalShareClassifierTest < ActiveSupport::TestCase
  TENANT = "tnt_federal_share_classifier"

  test "tribal-facility claim gets 100 percent federal share even when the patient's AI/AN status is unknown" do
    with_tenant(TENANT) do
      claim = tribal_facility_claim(american_indian_alaska_native: nil)

      determination = Corvid::MedicaidFederalShareClassifier.classify!(
        claim, tribal_facility_identifier: "fac_fsc", patient_identifier: claim.patient_identifier
      )

      assert_equal 100, determination.federal_percent
      assert_equal 0, determination.state_percent
      assert_includes determination.basis_tokens, "SSA 1905(b)"
      refute_includes determination.basis_tokens, "ai_an_beneficiary"
    end
  end

  test "tribal-facility claim gets 100 percent federal share even when the patient is explicitly not AI/AN" do
    with_tenant(TENANT) do
      claim = tribal_facility_claim(american_indian_alaska_native: false)

      determination = Corvid::MedicaidFederalShareClassifier.classify!(
        claim, tribal_facility_identifier: "fac_fsc", patient_identifier: claim.patient_identifier
      )

      assert_equal 100, determination.federal_percent, "SSA 1905(b)'s 100% FMAP is facility-based, not beneficiary-identity-based"
    end
  end

  private

  def tribal_facility_claim(american_indian_alaska_native:)
    patient_identifier = "pt_fsc_#{SecureRandom.hex(4)}"
    Corvid.adapter.add_patient(patient_identifier,
      display_name: "TEST,PATIENT", dob: Date.new(1980, 1, 1), sex: "F", ssn_last4: "1111",
      american_indian_alaska_native: american_indian_alaska_native
    )

    Corvid::ClaimSubmission.create!(
      tenant_identifier: TENANT, facility_identifier: "fac_fsc",
      patient_identifier: patient_identifier, claim_type: "professional",
      service_date: Date.current, billed_amount: 100.0
    )
  end
end
