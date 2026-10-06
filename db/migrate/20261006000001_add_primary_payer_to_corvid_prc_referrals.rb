# frozen_string_literal: true

# corvid#595: the referral needs a durable record of which payer is
# primary (Medicaid vs the programme's own capped appropriation) so
# payer-of-last-resort is a recorded fact, not something re-derived from
# whatever alternate-resource checks happen to say at query time. NULL
# means "not yet designated" — Corvid::MedicaidReferralWorkflow treats
# that as "programme" (the default payer of last resort), never as
# Medicaid by omission.
class AddPrimaryPayerToCorvidPrcReferrals < ActiveRecord::Migration[8.1]
  def change
    add_column :corvid_prc_referrals, :primary_payer, :string

    add_check_constraint :corvid_prc_referrals,
      "primary_payer IS NULL OR primary_payer IN ('medicaid', 'programme')",
      name: "corvid_prc_referrals_primary_payer_check"
  end
end
