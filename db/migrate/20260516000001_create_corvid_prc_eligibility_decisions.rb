# frozen_string_literal: true

class CreateCorvidPrcEligibilityDecisions < ActiveRecord::Migration[8.1]
  def change
    # One row per TribalEligibilityService.decide call. Audit-defensible
    # documentation that addresses real PRC audit findings around
    # eligibility provenance, reproducibility, and structured reason codes.
    create_table :corvid_prc_eligibility_decisions do |t|
      t.string :tenant_identifier, null: false
      t.string :person_identifier, null: false
      t.string :facility_identifier, null: false
      t.string :decided_by_identifier
      t.datetime :decided_at, null: false
      t.date :as_of_date, null: false

      t.boolean :eligible, null: false

      # JSON array of stable enum symbol strings (e.g., "not_enrolled",
      # "not_enrolled_in_contracted_tribe", "off_reservation",
      # "provider_unavailable_fail_closed").
      t.jsonb :reason_codes, null: false, default: []

      # Provenance: which adapter produced the underlying verification
      # data, and how confident the source said it was.
      t.string :provider_source
      t.string :provider_confidence

      # SHA256 of the raw provider response payload — for reproducibility
      # checks without storing PHI. A later re-verify with the same inputs
      # and same upstream snapshot should produce the same hash.
      t.string :verification_snapshot_hash

      t.timestamps
    end

    add_index :corvid_prc_eligibility_decisions,
              [ :tenant_identifier, :decided_at ],
              name: "idx_corvid_prc_eligibility_decisions_tenant_decided_at"

    add_index :corvid_prc_eligibility_decisions,
              [ :tenant_identifier, :person_identifier, :decided_at ],
              name: "idx_corvid_prc_elig_decisions_tenant_person_decided"

    add_index :corvid_prc_eligibility_decisions,
              [ :tenant_identifier, :facility_identifier, :decided_at ],
              name: "idx_corvid_prc_elig_decisions_tenant_facility_decided"
  end
end
