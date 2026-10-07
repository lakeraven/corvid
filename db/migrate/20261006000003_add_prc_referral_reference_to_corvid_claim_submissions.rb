# frozen_string_literal: true

# Without this reference a claim can only be traced back to the referral it
# bills through the loose referral_identifier string, so an obligation against
# a capped appropriation cannot be reconciled against the care that was
# actually authorized. Nullable: legacy claims and claims billed outside the
# referral workflow keep working, and Corvid::ClaimSubmission resolves the
# reference from referral_identifier when it is not set explicitly.
#
# Adding the column alone would orphan every claim that already exists at
# deploy time, because the model's resolver only fires on save and never
# retroactively. #up therefore backfills with the same rule the model applies
# going forward.
#
# That rule refuses to guess, on two counts.
#
# The referral must belong to the same patient. A single match on facility and
# identifier says nothing about whose care it authorized, so joining through
# the referral's case is what stops patient B's claim being linked to patient
# A's referral — and then billed against A's authorization.
#
# And the match must be unique. PrcReferral scopes uniqueness to
# [tenant_identifier, facility_identifier], which does NOT make a match unique:
# PostgreSQL treats NULLs as distinct in a unique index, so any number of
# referrals may share a tenant and identifier while facility_identifier is
# NULL. Matching with IS NOT DISTINCT FROM and taking whatever came back would
# link a claim to an arbitrary one of them — reconciling one patient's claim
# against another patient's referral. A claim is linked only where exactly one
# referral matches; everything else is left NULL for a human to resolve, since
# no automatic guess is safe.
class AddPrcReferralReferenceToCorvidClaimSubmissions < ActiveRecord::Migration[8.1]
  def up
    add_reference :corvid_claim_submissions, :prc_referral,
      foreign_key: { to_table: :corvid_prc_referrals },
      index: true

    backfill_prc_referral_from_identifier
  end

  def down
    # to_table has to be named here too: inferred from the column, Rails looks
    # for a `prc_referrals` table, which does not exist, and the rollback
    # raises before it removes anything.
    remove_reference :corvid_claim_submissions, :prc_referral,
      foreign_key: { to_table: :corvid_prc_referrals },
      index: true
  end

  private

  def backfill_prc_referral_from_identifier
    execute(<<~SQL.squish)
      UPDATE corvid_claim_submissions AS claims
      SET prc_referral_id = unambiguous.referral_id
      FROM (
        SELECT c.id AS claim_id,
               MIN(r.id) AS referral_id,
               COUNT(*) AS match_count
        FROM corvid_claim_submissions AS c
        JOIN corvid_prc_referrals AS r
          ON c.referral_identifier = r.referral_identifier
         AND c.tenant_identifier = r.tenant_identifier
         AND c.facility_identifier IS NOT DISTINCT FROM r.facility_identifier
        JOIN corvid_cases AS k
          ON k.id = r.case_id
         AND k.patient_identifier = c.patient_identifier
        WHERE c.prc_referral_id IS NULL
          AND c.referral_identifier IS NOT NULL
        GROUP BY c.id
      ) AS unambiguous
      WHERE claims.id = unambiguous.claim_id
        AND unambiguous.match_count = 1
    SQL
  end
end
