# frozen_string_literal: true

# Nullable on purpose. Set in phase A of every Medicaid hold override
# submit, before the clearinghouse is called, and cleared when that
# result is recorded. An adapter error leaves it set until staff
# reconcile the send.
class AddSubmissionOutcomeUnknownAtToClaimSubmissions < ActiveRecord::Migration[8.1]
  def change
    add_column :corvid_claim_submissions, :submission_outcome_unknown_at, :datetime
  end
end
