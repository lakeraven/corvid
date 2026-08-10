# frozen_string_literal: true

class CreateCorvidMedicaidExemptions < ActiveRecord::Migration[8.1]
  EXEMPTION_TYPES = %w[work_requirement six_month_redetermination].freeze
  STATUSES = %w[asserted expired revoked].freeze

  def change
    # An AI/AN Medicaid exemption carried on the member record, sourced from a
    # verified assertion (never self-report). Under HR-1 (2025 reconciliation),
    # American Indians/Alaska Natives — including Urban Indians — are exempt
    # from Medicaid community-engagement/work requirements and from the
    # 6-month eligibility redeterminations that begin January 2027.
    #
    # One asserted row per (tenant, person, exemption_type). Re-asserting
    # refreshes the same row so verification provenance stays current.
    create_table :corvid_medicaid_exemptions do |t|
      t.string :tenant_identifier, null: false
      t.string :facility_identifier
      t.string :person_identifier, null: false

      t.string :exemption_type, null: false
      t.string :status, null: false, default: "asserted"

      # Why the exemption applies (e.g. "ai_an_ihs_beneficiary"). Statutory
      # basis is the same for both exemption types; kept for audit clarity.
      t.string :basis

      t.date :as_of_date
      t.date :effective_date
      t.datetime :expires_at

      # Verification provenance — mirrors PrcEligibilityDecision. The
      # verified-status source is baseroll's IAL2/AAL2 verification, reached
      # through the adapter. No PHI is stored: only provenance metadata.
      t.datetime :verified_at
      t.string :verification_source
      t.string :verification_confidence
      t.string :verification_snapshot_hash
      t.string :asserted_by_identifier

      t.timestamps
    end

    add_index :corvid_medicaid_exemptions,
              [ :tenant_identifier, :person_identifier ],
              name: "idx_corvid_medicaid_exemptions_tenant_person"

    add_index :corvid_medicaid_exemptions,
              [ :tenant_identifier, :status, :exemption_type ],
              name: "idx_corvid_medicaid_exemptions_tenant_status_type"

    # At most one *asserted* exemption of a given type per person.
    add_index :corvid_medicaid_exemptions,
              [ :tenant_identifier, :person_identifier, :exemption_type ],
              unique: true,
              where: "status = 'asserted'",
              name: "idx_corvid_medicaid_exemptions_active_unique"

    add_check_constraint :corvid_medicaid_exemptions,
      "exemption_type IN (#{EXEMPTION_TYPES.map { |s| "'#{s}'" }.join(',')})",
      name: "corvid_medicaid_exemptions_type_check"

    add_check_constraint :corvid_medicaid_exemptions,
      "status IN (#{STATUSES.map { |s| "'#{s}'" }.join(',')})",
      name: "corvid_medicaid_exemptions_status_check"
  end
end
