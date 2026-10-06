# frozen_string_literal: true

# corvid#595: without this FK a claim can only be traced back to the
# referral it bills via the loose referral_identifier string, so an
# obligation against a capped appropriation can't be reconciled against
# delivered care. Nullable/optional — legacy claims and claims billed
# outside the referral workflow keep working; Corvid::ClaimSubmission
# resolves it from referral_identifier when not set explicitly.
#
# Review finding (PR #598): adding the column alone orphans every claim
# that already exists at deploy time — ClaimSubmission's before_validation
# resolver only fires on save, never retroactively. #up backfills existing
# rows with the same match the model uses going forward: tenant +
# facility + referral_identifier (PrcReferral's own uniqueness scope, so
# at most one referral can ever match). A claim with no match — wrong
# facility, retired identifier, a referral_identifier that was never a
# real PrcReferral row — is left NULL rather than guessed at; there is no
# safe guess that doesn't risk reconciling against the wrong patient's care.
class AddPrcReferralReferenceToCorvidClaimSubmissions < ActiveRecord::Migration[8.1]
  def up
    add_reference :corvid_claim_submissions, :prc_referral,
                   foreign_key: { to_table: :corvid_prc_referrals },
                   index: true

    backfill_prc_referral_from_identifier
  end

  def down
    remove_reference :corvid_claim_submissions, :prc_referral, foreign_key: true, index: true
  end

  private

  def backfill_prc_referral_from_identifier
    execute(<<~SQL.squish)
      UPDATE corvid_claim_submissions AS claims
      SET prc_referral_id = referrals.id
      FROM corvid_prc_referrals AS referrals
      WHERE claims.prc_referral_id IS NULL
        AND claims.referral_identifier IS NOT NULL
        AND claims.referral_identifier = referrals.referral_identifier
        AND claims.tenant_identifier = referrals.tenant_identifier
        AND claims.facility_identifier IS NOT DISTINCT FROM referrals.facility_identifier
    SQL
  end
end
