# frozen_string_literal: true

# A rejection and a denial are different events and need different work.
#
# A rejection happens before the payer adjudicates: the clearinghouse or the
# payer's front end refuses the claim (999 / 277CA) for something like a bad
# member ID. Nothing was decided about payment, and the fix is to correct the
# claim and resubmit.
#
# A denial is the payer's adjudicated decision not to pay, reported on the 835
# with CARC/RARC adjustment codes. The fix is an appeal, a corrected claim, or
# a write-off.
#
# Until now both landed in denial_reason_token and nothing recorded that a
# claim had ever been rejected or denied once its status moved on (resubmitted,
# appealed, eventually paid). That makes rejection rate, denial rate and
# first-pass rate impossible to compute. This migration adds:
#
#   rejection_reason_token - vault token for the front-end rejection reason
#   denial_reason_codes    - CARC/RARC codes from the 835 (e.g. "CO-97").
#                            These are standard code-set values, not PHI.
#   rejected_at, denied_at - when the claim first entered each state. They are
#                            kept after the status moves on, so a claim that
#                            was rejected and later paid still counts against
#                            first-pass rate.
#
# #up backfills from what exists today. mark_rejected! wrote the rejection
# reason into denial_reason_token, so rows whose status is "rejected" have that
# token moved across. Rows currently rejected or denied get updated_at as their
# best-known transition time. Claims that were rejected or denied in the past
# but have since moved on left no trace and cannot be recovered.
class SeparateRejectionFromDenialOnCorvidClaimSubmissions < ActiveRecord::Migration[8.1]
  def up
    add_column :corvid_claim_submissions, :rejection_reason_token, :string
    add_column :corvid_claim_submissions, :denial_reason_codes, :string, array: true, default: [], null: false
    add_column :corvid_claim_submissions, :rejected_at, :datetime
    add_column :corvid_claim_submissions, :denied_at, :datetime

    execute(<<~SQL.squish)
      UPDATE corvid_claim_submissions
      SET rejection_reason_token = denial_reason_token,
          denial_reason_token = NULL,
          rejected_at = updated_at
      WHERE status = 'rejected'
    SQL

    execute(<<~SQL.squish)
      UPDATE corvid_claim_submissions
      SET denied_at = updated_at
      WHERE status = 'denied'
    SQL
  end

  def down
    execute(<<~SQL.squish)
      UPDATE corvid_claim_submissions
      SET denial_reason_token = rejection_reason_token
      WHERE status = 'rejected' AND rejection_reason_token IS NOT NULL
    SQL

    remove_column :corvid_claim_submissions, :denied_at
    remove_column :corvid_claim_submissions, :rejected_at
    remove_column :corvid_claim_submissions, :denial_reason_codes
    remove_column :corvid_claim_submissions, :rejection_reason_token
  end
end
