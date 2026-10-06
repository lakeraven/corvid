# frozen_string_literal: true

# corvid#595: without this FK a claim can only be traced back to the
# referral it bills via the loose referral_identifier string, so an
# obligation against a capped appropriation can't be reconciled against
# delivered care. Nullable/optional — legacy claims and claims billed
# outside the referral workflow keep working; Corvid::ClaimSubmission
# resolves it from referral_identifier when not set explicitly.
class AddPrcReferralReferenceToCorvidClaimSubmissions < ActiveRecord::Migration[8.1]
  def change
    add_reference :corvid_claim_submissions, :prc_referral,
                   foreign_key: { to_table: :corvid_prc_referrals },
                   index: true
  end
end
