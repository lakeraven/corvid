# frozen_string_literal: true

class AddErrorStatusToClaimSubmissions < ActiveRecord::Migration[8.1]
  STATUSES = %w[draft submitted accepted rejected paid denied appealed error].freeze

  def up
    remove_check_constraint :corvid_claim_submissions, name: "corvid_claim_submissions_status_check"
    add_check_constraint :corvid_claim_submissions,
      "status IN (#{STATUSES.map { |s| "'#{s}'" }.join(',')})",
      name: "corvid_claim_submissions_status_check"
  end

  def down
    execute "UPDATE corvid_claim_submissions SET status = 'rejected' WHERE status = 'error'"
    remove_check_constraint :corvid_claim_submissions, name: "corvid_claim_submissions_status_check"
    old_statuses = STATUSES - %w[error]
    add_check_constraint :corvid_claim_submissions,
      "status IN (#{old_statuses.map { |s| "'#{s}'" }.join(',')})",
      name: "corvid_claim_submissions_status_check"
  end
end
