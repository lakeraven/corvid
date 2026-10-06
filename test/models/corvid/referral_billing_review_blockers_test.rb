# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

# Review findings on PR #598 (independent gate seat, confirmed against the
# code). Each test here fails without its corresponding fix.
class Corvid::ReferralBillingReviewBlockersTest < ActiveSupport::TestCase
  TENANT = "tnt_review_blockers"

  # --- Finding: submit! enforces fulfilment but not authorization -----------
  #
  # The gate added in the previous round checks only that care was delivered.
  # A referral still in `draft` — never submitted, never reviewed, never
  # approved — can therefore be billed as soon as a fulfilment report lands.

  test "submit! refuses a referral that was never authorized" do
    with_tenant(TENANT) do
      referral = draft_referral("rb_unauth_1")
      claim = claim_for(referral)
      deliver!(referral)

      assert_equal "draft", referral.reload.status,
        "precondition: the referral must be unauthorized"

      assert_raises(Corvid::ClaimSubmission::ReferralNotAuthorized) do
        claim.submit!
      end
      assert_equal "draft", claim.reload.status,
        "a refused submission must not advance the claim"
    end
  end

  test "submit! proceeds for an authorized referral with delivered care" do
    with_tenant(TENANT) do
      referral = authorized_referral("rb_auth_1")
      claim = claim_for(referral)
      deliver!(referral)

      claim.submit!
      assert_equal "submitted", claim.reload.status
    end
  end

  # --- Finding: fulfilment history is not append-only ----------------------
  #
  # `has_many :fulfilment_reports, dependent: :destroy` erases the audit trail
  # whenever a referral is destroyed, and the reports themselves accept
  # `destroy` and `update`. "Append-only" has to be enforced, not just named
  # in a comment.

  test "destroying a referral does not erase its fulfilment reports" do
    with_tenant(TENANT) do
      referral = authorized_referral("rb_append_1")
      deliver!(referral)
      report_count = Corvid::ReferralFulfilmentReport.where(prc_referral_id: referral.id).count
      assert_operator report_count, :>, 0, "precondition: a report exists"

      assert_raises(ActiveRecord::RecordNotDestroyed, ActiveRecord::InvalidForeignKey) do
        referral.destroy!
      end

      assert_equal report_count,
        Corvid::ReferralFulfilmentReport.where(prc_referral_id: referral.id).count,
        "fulfilment reports must survive an attempt to destroy the referral"
    end
  end

  test "a fulfilment report cannot be destroyed" do
    with_tenant(TENANT) do
      referral = authorized_referral("rb_append_2")
      deliver!(referral)
      report = Corvid::ReferralFulfilmentReport.where(prc_referral_id: referral.id).first

      assert_raises(ActiveRecord::RecordNotDestroyed) { report.destroy! }
      assert Corvid::ReferralFulfilmentReport.exists?(report.id)
    end
  end

  test "a fulfilment report cannot be rewritten after it is recorded" do
    with_tenant(TENANT) do
      referral = authorized_referral("rb_append_3")
      deliver!(referral)
      report = Corvid::ReferralFulfilmentReport.where(prc_referral_id: referral.id).first

      assert_raises(ActiveRecord::RecordNotSaved) { report.update!(outcome: "not_delivered") }
      assert_equal "delivered", report.reload.outcome
    end
  end

  # --- Finding: any positive payment closes the claim ----------------------
  #
  # A $100 remittance against a $425 claim marked the claim `paid`. In an 835
  # the claim is satisfied only when paid + adjustments + patient
  # responsibility accounts for the billed amount.

  test "a partial payment leaves the claim outstanding" do
    with_tenant(TENANT) do
      claim = claim_for(authorized_referral("rb_partial_1"), billed: 425.0)
      claim.update!(status: "accepted", claim_identifier: "clm_partial_1")

      apply_remittance!(claim, paid: 100.0)

      refute_equal "paid", claim.reload.status,
        "a $100 payment against a $425 claim must not close it"
      assert_equal 100.0, claim.paid_amount.to_f
    end
  end

  test "a payment plus adjustments that accounts for the billed amount closes the claim" do
    with_tenant(TENANT) do
      claim = claim_for(authorized_referral("rb_full_1"), billed: 425.0)
      claim.update!(status: "accepted", claim_identifier: "clm_full_1")

      apply_remittance!(claim, paid: 300.0, adjustment: 100.0, patient_responsibility: 25.0)

      assert_equal "paid", claim.reload.status
    end
  end

  test "a zero payment does not close the claim" do
    with_tenant(TENANT) do
      claim = claim_for(authorized_referral("rb_zero_1"), billed: 425.0)
      claim.update!(status: "accepted", claim_identifier: "clm_zero_1")

      apply_remittance!(claim, paid: 0.0)

      refute_equal "paid", claim.reload.status
    end
  end

  private

  def draft_referral(id)
    kase = Corvid::Case.create!(patient_identifier: "pt_#{id}", facility_identifier: "fac_rb")
    Corvid::PrcReferral.create!(case: kase, referral_identifier: id, facility_identifier: "fac_rb")
  end

  def authorized_referral(id)
    referral = draft_referral(id)
    Corvid::MedicaidReferralWorkflow.bootstrap_authorized_medicaid_referral!(referral)
    referral.reload
  end

  def claim_for(referral, billed: 100.0)
    Corvid::ClaimSubmission.create!(
      tenant_identifier: TENANT, facility_identifier: referral.facility_identifier,
      patient_identifier: referral.case.patient_identifier, prc_referral: referral,
      referral_identifier: referral.referral_identifier, claim_type: "professional",
      service_date: Date.current, billed_amount: billed, status: "draft"
    )
  end

  def deliver!(referral)
    Corvid::ReferralFulfilment.record_external_report!(
      referral, source: "receiving_specialist", outcome: "delivered",
      reported_at: Time.current
    )
  end

  def apply_remittance!(claim, paid:, adjustment: nil, patient_responsibility: nil)
    line = { claim_identifier: claim.claim_identifier, paid_amount: paid }
    line[:adjustment_amount] = adjustment if adjustment
    line[:patient_responsibility] = patient_responsibility if patient_responsibility

    Corvid.adapter.stub(:fetch_remittances,
      [ { payment_date: Date.current, line_items: [ line ] } ]) do
      Corvid::ReferralBillingReconciliation.send(:apply_remittance!, claim)
    end
  end
end
