# frozen_string_literal: true

require "test_helper"

# Review finding (PR #598, medium): "Require active Medicaid coverage
# before changing payer" — record_medicaid_primary_payer! set
# primary_payer: "medicaid" (which, per its own doc comment, deliberately
# skips reserving programme appropriation funds) without checking that
# the referral actually has a verified, active Medicaid
# AlternateResourceCheck. Any caller could therefore create an unfunded
# referral just by invoking the public method.
class Corvid::MedicaidReferralWorkflowCoverageTest < ActiveSupport::TestCase
  TENANT = "tnt_medicaid_coverage"

  test "record_medicaid_primary_payer! rejects a referral with no verified Medicaid coverage" do
    with_tenant(TENANT) do
      referral = create_referral("rf_cov_none")

      assert_raises(Corvid::MedicaidReferralWorkflow::UnverifiedMedicaidCoverage) do
        Corvid::MedicaidReferralWorkflow.record_medicaid_primary_payer!(referral)
      end
      assert_nil referral.reload.primary_payer
    end
  end

  test "record_medicaid_primary_payer! rejects a referral whose Medicaid check is not_enrolled" do
    with_tenant(TENANT) do
      referral = create_referral("rf_cov_denied")
      referral.alternate_resource_checks.create!(resource_type: "medicaid", status: :not_enrolled)

      assert_raises(Corvid::MedicaidReferralWorkflow::UnverifiedMedicaidCoverage) do
        Corvid::MedicaidReferralWorkflow.record_medicaid_primary_payer!(referral)
      end
    end
  end

  test "record_medicaid_primary_payer! succeeds once Medicaid coverage is verified enrolled" do
    with_tenant(TENANT) do
      referral = create_referral("rf_cov_enrolled")
      referral.alternate_resource_checks.create!(resource_type: "medicaid", status: :enrolled)

      Corvid::MedicaidReferralWorkflow.record_medicaid_primary_payer!(referral)
      assert_equal "medicaid", referral.reload.primary_payer
    end
  end

  test "bootstrap_authorized_medicaid_referral! verifies Medicaid coverage itself rather than defaulting it" do
    with_tenant(TENANT) do
      referral = create_referral("rf_cov_bootstrap")
      refute referral.alternate_resource_checks.exists?(resource_type: "medicaid")

      Corvid::MedicaidReferralWorkflow.bootstrap_authorized_medicaid_referral!(referral)
      referral.reload

      assert_equal "medicaid", referral.primary_payer
      check = referral.alternate_resource_checks.find_by(resource_type: "medicaid")
      refute_nil check
      assert check.has_coverage?
      assert referral.authorized?
    end
  end

  private

  def create_referral(referral_id)
    kase = Corvid::Case.create!(patient_identifier: "pt_#{referral_id}", facility_identifier: "fac_cov")
    Corvid::PrcReferral.create!(case: kase, referral_identifier: referral_id, facility_identifier: "fac_cov")
  end
end
