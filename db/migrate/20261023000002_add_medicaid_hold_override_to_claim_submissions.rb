# frozen_string_literal: true

# ADR 0003: the reason a staff member released a claim from the pending
# Medicaid hold is a vault token, never free text. The token, the staff
# identifier, and the time are recorded together or not at all.
class AddMedicaidHoldOverrideToClaimSubmissions < ActiveRecord::Migration[8.1]
  def up
    add_override_columns
    add_override_check
  end

  def down
    remove_check_constraint :corvid_claim_submissions,
      name: "corvid_claim_submissions_medicaid_hold_override_check"
    remove_override_columns
  end

  private

  def add_override_columns
    add_column :corvid_claim_submissions, :medicaid_hold_override_reason_token, :string
    add_column :corvid_claim_submissions, :medicaid_hold_override_by_identifier, :string
    add_column :corvid_claim_submissions, :medicaid_hold_overridden_at, :datetime
  end

  def remove_override_columns
    remove_column :corvid_claim_submissions, :medicaid_hold_overridden_at
    remove_column :corvid_claim_submissions, :medicaid_hold_override_by_identifier
    remove_column :corvid_claim_submissions, :medicaid_hold_override_reason_token
  end

  def add_override_check
    add_check_constraint :corvid_claim_submissions,
      override_sql,
      name: "corvid_claim_submissions_medicaid_hold_override_check"
  end

  def override_sql
    <<~SQL.squish
      (
        medicaid_hold_override_reason_token IS NULL AND
        medicaid_hold_override_by_identifier IS NULL AND
        medicaid_hold_overridden_at IS NULL
      ) OR (
        medicaid_hold_override_reason_token IS NOT NULL AND
        medicaid_hold_override_by_identifier IS NOT NULL AND
        medicaid_hold_overridden_at IS NOT NULL
      )
    SQL
  end
end
