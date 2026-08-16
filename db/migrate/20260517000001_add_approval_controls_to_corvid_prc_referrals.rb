# frozen_string_literal: true

# #478 management-approval gate controls: record the submitter (for
# dual-control: approver must differ from submitter) and the manager
# return/reject decision (reason token per the PHI-token pattern).
class AddApprovalControlsToCorvidPrcReferrals < ActiveRecord::Migration[8.1]
  def change
    add_column :corvid_prc_referrals, :submitted_by_identifier, :string
    add_column :corvid_prc_referrals, :management_rejected_at, :datetime
    add_column :corvid_prc_referrals, :management_rejected_by_identifier, :string
    add_column :corvid_prc_referrals, :management_rejection_reason_token, :string
  end
end
