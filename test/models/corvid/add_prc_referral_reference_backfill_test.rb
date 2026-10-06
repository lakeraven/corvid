# frozen_string_literal: true

require "test_helper"
require_relative "../../../db/migrate/20261006000003_add_prc_referral_reference_to_corvid_claim_submissions"

# Review finding (PR #598, medium): "Backfill existing claims from referral
# identifiers" — the migration added a nullable prc_referral_id column and
# FK but never populated it, so claims that existed before this PR deployed
# would stay orphaned forever (ClaimSubmission#resolve_prc_referral_from_identifier
# only runs on save, never retroactively). Exercises the migration's own
# backfill directly against rows that stand in for pre-#595 legacy claims.
class AddPrcReferralReferenceBackfillTest < ActiveSupport::TestCase
  TENANT = "tnt_backfill_migration"

  test "backfills a legacy claim matched by tenant, facility, and referral_identifier" do
    with_tenant(TENANT) do
      referral = create_referral("rf_bf_1", "fac_a")
      claim = create_legacy_claim("fac_a", "rf_bf_1")

      run_backfill!

      assert_equal referral.id, claim.reload.prc_referral_id
    end
  end

  test "does not backfill across facilities even when the identifier string matches" do
    with_tenant(TENANT) do
      create_referral("rf_bf_shared", "fac_other")
      claim = create_legacy_claim("fac_b", "rf_bf_shared")

      run_backfill!

      assert_nil claim.reload.prc_referral_id,
        "A referral at a different facility must never be linked, even with a matching identifier string"
    end
  end

  test "leaves a claim with no matching referral at all untouched" do
    with_tenant(TENANT) do
      claim = create_legacy_claim("fac_c", "rf_bf_no_match")

      run_backfill!

      assert_nil claim.reload.prc_referral_id
    end
  end

  private

  def run_backfill!
    AddPrcReferralReferenceToCorvidClaimSubmissions.new.send(:backfill_prc_referral_from_identifier)
  end

  def create_referral(referral_id, facility_identifier)
    kase = Corvid::Case.create!(patient_identifier: "pt_#{referral_id}", facility_identifier: facility_identifier)
    Corvid::PrcReferral.create!(case: kase, referral_identifier: referral_id, facility_identifier: facility_identifier)
  end

  # Simulates a row that predates this PR's before_validation auto-resolve:
  # create normally, then strip prc_referral_id as the migration will find it.
  def create_legacy_claim(facility_identifier, referral_identifier)
    claim = Corvid::ClaimSubmission.create!(
      tenant_identifier: TENANT, facility_identifier: facility_identifier,
      patient_identifier: "pt_legacy_#{referral_identifier}", referral_identifier: referral_identifier,
      claim_type: "professional", service_date: Date.current, billed_amount: 100.0
    )
    claim.update_column(:prc_referral_id, nil)
    claim
  end
end
