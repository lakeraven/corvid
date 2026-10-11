# frozen_string_literal: true

# One row per AianExemptionService#determine call (ADR 0007). Records which
# H.R. 1 AI/AN exemption bases were established and by which sources, without
# storing PHI: evidence rows carry basis, source class and confidence only.
class CreateCorvidAianExemptionDeterminations < ActiveRecord::Migration[8.1]
  STATUSES = %w[exempt not_established unavailable].freeze

  def change
    create_table :corvid_aian_exemption_determinations do |t|
      t.string :tenant_identifier, null: false
      t.string :facility_identifier
      t.string :person_identifier, null: false
      t.string :decided_by_identifier
      t.datetime :decided_at, null: false
      t.date :as_of_date, null: false

      t.string :status, null: false

      # JSON arrays of stable enum strings, e.g. ["enrolled_tribal_member"].
      t.jsonb :bases, null: false, default: []
      t.jsonb :warnings, null: false, default: []

      # [{ basis:, source:, confidence: }] — no identifiers, dates or payloads.
      t.jsonb :evidence, null: false, default: []

      # SHA256 of the raw source responses, for reproducibility checks.
      t.string :verification_snapshot_hash

      t.timestamps
    end

    add_index :corvid_aian_exemption_determinations,
              [ :tenant_identifier, :person_identifier, :decided_at ],
              name: "idx_corvid_aian_determinations_tenant_person_decided"

    add_check_constraint :corvid_aian_exemption_determinations,
      "status IN (#{STATUSES.map { |s| "'#{s}'" }.join(',')})",
      name: "corvid_aian_determinations_status_check"
  end
end
