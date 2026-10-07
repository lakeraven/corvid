# frozen_string_literal: true

require "test_helper"
require Rails.root.join("..", "..", "db", "migrate",
  "20261006000003_add_prc_referral_reference_to_corvid_claim_submissions").to_s

# The backfill runs once, against rows nobody is watching, and a wrong link
# there reconciles one patient's claim against another patient's referral.
# These exercise the SQL itself: the model's resolver never touches existing
# rows, so the two paths can disagree, and the backfill is the one that runs
# unsupervised.
class Corvid::ClaimReferralBackfillTest < ActiveSupport::TestCase
  TENANT = "tnt_backfill"

  setup do
    @migration = AddPrcReferralReferenceToCorvidClaimSubmissions.new
  end

  test "a claim with exactly one matching referral is linked" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "BF-1")
      claim = unlinked_claim(facility: "fac_a", referral_identifier: "BF-1",
        patient: referral.case.patient_identifier)

      backfill!

      assert_equal referral.id, claim.reload.prc_referral_id
    end
  end

  test "a claim is not linked across facilities" do
    with_tenant(TENANT) do
      referral_at("fac_a", "BF-2")
      claim = unlinked_claim(facility: "fac_b", referral_identifier: "BF-2")

      backfill!

      assert_nil claim.reload.prc_referral_id
    end
  end

  # PostgreSQL treats NULLs as distinct in a unique index, so PrcReferral's
  # [tenant, facility] uniqueness scope does not make this match unique. An
  # IS NOT DISTINCT FROM join alone would link the claim to whichever row the
  # planner happened to return.
  test "a claim matching several NULL-facility referrals is left alone" do
    with_tenant(TENANT) do
      first = referral_at(nil, "BF-3")
      second = duplicate_referral_at(nil, "BF-3")
      claim = unlinked_claim(facility: nil, referral_identifier: "BF-3")

      backfill!

      assert_nil claim.reload.prc_referral_id,
        "linking to either of #{[ first.id, second.id ].inspect} would be a guess"
    end
  end

  # A single match on facility and identifier says nothing about whose care the
  # referral authorized. Linking on that alone would hand patient B's claim to
  # patient A's referral, in a one-shot migration nobody is watching.
  test "a claim is not linked to another patient's referral" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "BF-XPAT")
      claim = unlinked_claim(facility: "fac_a", referral_identifier: "BF-XPAT")
      refute_equal referral.case.patient_identifier, claim.patient_identifier, "precondition"

      backfill!

      assert_nil claim.reload.prc_referral_id,
        "the referral belongs to a different patient"
    end
  end

  test "a claim is linked when the referral is for the same patient" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "BF-SAMEPT")
      claim = unlinked_claim(facility: "fac_a", referral_identifier: "BF-SAMEPT",
        patient: referral.case.patient_identifier)

      backfill!

      assert_equal referral.id, claim.reload.prc_referral_id
    end
  end

  test "a claim whose identifier matches nothing is left alone" do
    with_tenant(TENANT) do
      claim = unlinked_claim(facility: "fac_a", referral_identifier: "BF-NOTHING")

      backfill!

      assert_nil claim.reload.prc_referral_id
    end
  end

  test "a claim already linked is not relinked" do
    with_tenant(TENANT) do
      intended = referral_at("fac_a", "BF-5")
      other = referral_at("fac_a", "BF-5-OTHER")
      claim = unlinked_claim(facility: "fac_a", referral_identifier: "BF-5")
      claim.update_column(:prc_referral_id, other.id)

      backfill!

      assert_equal other.id, claim.reload.prc_referral_id,
        "an existing link is a decision already made; the backfill fills gaps"
      refute_equal intended.id, claim.prc_referral_id
    end
  end

  test "the backfill is idempotent" do
    with_tenant(TENANT) do
      referral = referral_at("fac_a", "BF-6")
      claim = unlinked_claim(facility: "fac_a", referral_identifier: "BF-6",
        patient: referral.case.patient_identifier)

      backfill!
      first_pass = claim.reload.prc_referral_id
      backfill!

      assert_equal referral.id, first_pass
      assert_equal first_pass, claim.reload.prc_referral_id
    end
  end

  private

  def backfill!
    @migration.send(:backfill_prc_referral_from_identifier)
  end

  def referral_at(facility, identifier)
    kase = Corvid::Case.create!(
      patient_identifier: "pt_#{identifier}_#{SecureRandom.hex(3)}", facility_identifier: facility
    )
    Corvid::PrcReferral.create!(
      case: kase, referral_identifier: identifier, facility_identifier: facility
    )
  end

  # See claim_referral_link_test.rb: the database permits this row even though
  # Rails' uniqueness validation does not, so it arrives by import or by SQL.
  def duplicate_referral_at(facility, identifier)
    kase = Corvid::Case.create!(
      patient_identifier: "pt_dup_#{identifier}_#{SecureRandom.hex(3)}", facility_identifier: facility
    )
    referral = Corvid::PrcReferral.new(
      case: kase, referral_identifier: identifier, facility_identifier: facility
    )
    referral.save!(validate: false)
    referral
  end

  # A row as it exists before the migration: identifier present, reference
  # NULL. The model's resolver would fill it on save, so it is cleared after
  # creation to reproduce the pre-migration state the backfill actually meets.
  def unlinked_claim(facility:, referral_identifier:, patient: nil)
    claim = Corvid::ClaimSubmission.create!(
      tenant_identifier: TENANT, facility_identifier: facility,
      patient_identifier: patient || "pt_claim_#{SecureRandom.hex(3)}",
      referral_identifier: referral_identifier, claim_type: "professional",
      service_date: Date.current, billed_amount: 100.0, status: "draft"
    )
    claim.update_column(:prc_referral_id, nil)
    claim
  end
end
