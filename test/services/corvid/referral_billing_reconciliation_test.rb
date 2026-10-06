# frozen_string_literal: true

require "test_helper"

# Review finding (PR #598, high): "Validate claim and referral association" —
# ReferralBillingReconciliation.reconcile! took `referral:` and `claim:` as
# independent arguments and never checked that the claim actually belongs
# to that referral, so a paid claim for one referral could be reported
# reconciled against a different (possibly delivered) referral.
class Corvid::ReferralBillingReconciliationAssociationTest < ActiveSupport::TestCase
  TENANT = "tnt_reconcile_assoc"

  test "reconcile! raises when the claim does not belong to the given referral" do
    with_tenant(TENANT) do
      referral_a = create_referral("rf_assoc_a")
      referral_b = create_referral("rf_assoc_b")
      claim_for_a = create_claim(referral_a)

      assert_raises(Corvid::ReferralBillingReconciliation::AssociationMismatch) do
        Corvid::ReferralBillingReconciliation.reconcile!(referral: referral_b, claim: claim_for_a)
      end
    end
  end

  test "reconcile! raises when the claim has no referral association at all" do
    with_tenant(TENANT) do
      referral = create_referral("rf_assoc_orphan")
      orphan_claim = Corvid::ClaimSubmission.create!(
        tenant_identifier: TENANT, facility_identifier: "fac_assoc",
        patient_identifier: "pt_orphan", claim_type: "professional",
        service_date: Date.current, billed_amount: 100.0, status: "accepted"
      )

      assert_raises(Corvid::ReferralBillingReconciliation::AssociationMismatch) do
        Corvid::ReferralBillingReconciliation.reconcile!(referral: referral, claim: orphan_claim)
      end
    end
  end

  test "reconcile! proceeds when the claim belongs to the given referral" do
    with_tenant(TENANT) do
      referral = create_referral("rf_assoc_match")
      claim = create_claim(referral)

      result = Corvid::ReferralBillingReconciliation.reconcile!(referral: referral, claim: claim)
      assert_equal referral.referral_identifier, result.referral_identifier
    end
  end

  private

  def create_referral(referral_id)
    kase = Corvid::Case.create!(patient_identifier: "pt_#{referral_id}", facility_identifier: "fac_assoc")
    Corvid::PrcReferral.create!(case: kase, referral_identifier: referral_id, facility_identifier: "fac_assoc")
  end

  def create_claim(referral)
    Corvid::ClaimSubmission.create!(
      tenant_identifier: TENANT, facility_identifier: referral.facility_identifier,
      patient_identifier: referral.case.patient_identifier, prc_referral: referral,
      referral_identifier: referral.referral_identifier, claim_type: "professional",
      service_date: Date.current, billed_amount: 100.0, status: "accepted"
    )
  end
end
