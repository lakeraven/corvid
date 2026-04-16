# frozen_string_literal: true

class AddCheckConstraintsToBillingTables < ActiveRecord::Migration[8.1]
  CLAIM_TYPES = %w[professional institutional dental].freeze
  BILLING_TX_STATUSES = %w[pending completed failed].freeze

  def up
    add_check_constraint :corvid_claim_submissions,
      "claim_type IN (#{CLAIM_TYPES.map { |s| "'#{s}'" }.join(',')})",
      name: "corvid_claim_submissions_type_check"

    add_check_constraint :corvid_billing_transactions,
      "status IN (#{BILLING_TX_STATUSES.map { |s| "'#{s}'" }.join(',')})",
      name: "corvid_billing_tx_status_check"
  end

  def down
    remove_check_constraint :corvid_claim_submissions, name: "corvid_claim_submissions_type_check"
    remove_check_constraint :corvid_billing_transactions, name: "corvid_billing_tx_status_check"
  end
end
