# frozen_string_literal: true

class CreateCorvidExemptionEvents < ActiveRecord::Migration[8.1]
  EVENT_TYPES = %w[
    asserted
    coverage_retained
    erroneously_disenrolled
    appeal_filed
    coverage_reinstated
    revoked
    expired
  ].freeze

  def change
    # Life-outcome events on an AI/AN Medicaid exemption: asserted, coverage
    # retained, erroneously disenrolled by administrative churn, appeal filed,
    # coverage reinstated. Distinct from a Determination (a decision outcome).
    #
    # This is the exemption-scoped precursor to the general Corvid::CaseOutcome
    # model (#332); when that lands, these events fold into it. Kept narrow and
    # standalone here so the exemption feature ships without waiting on #332.
    create_table :corvid_exemption_events do |t|
      t.string :tenant_identifier, null: false
      t.string :person_identifier, null: false

      # Optional link to the specific exemption. Person-level events
      # (e.g. erroneously_disenrolled) may not target one exemption row.
      t.references :medicaid_exemption,
                   null: true,
                   foreign_key: { to_table: :corvid_medicaid_exemptions }

      t.string :event_type, null: false
      t.string :exemption_type
      t.date :occurred_on, null: false
      t.string :recorded_by_identifier

      # Free text lives in the vault (ADR 0003); only the token is stored.
      t.string :notes_token

      t.timestamps
    end

    add_index :corvid_exemption_events,
              [ :tenant_identifier, :person_identifier, :occurred_on ],
              name: "idx_corvid_exemption_events_tenant_person_occurred"

    add_index :corvid_exemption_events,
              [ :tenant_identifier, :event_type ],
              name: "idx_corvid_exemption_events_tenant_type"

    add_check_constraint :corvid_exemption_events,
      "event_type IN (#{EVENT_TYPES.map { |s| "'#{s}'" }.join(',')})",
      name: "corvid_exemption_events_type_check"
  end
end
