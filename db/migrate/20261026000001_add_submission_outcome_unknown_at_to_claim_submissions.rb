# frozen_string_literal: true

# Nullable on purpose. Set only when a Medicaid hold override was spent
# for a send and the clearinghouse adapter then raised. Cleared once
# staff reconcile that send.
class AddSubmissionOutcomeUnknownAtToClaimSubmissions < ActiveRecord::Migration[8.1]
  def change
    add_column :corvid_claim_submissions, :submission_outcome_unknown_at, :datetime
  end
end
