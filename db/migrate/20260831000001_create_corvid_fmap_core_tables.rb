# frozen_string_literal: true

class CreateCorvidFmapCoreTables < ActiveRecord::Migration[8.1]
  def change
    # Statutory FMAP rules as data (#546): jurisdiction, citation, and
    # temporal validity live in rows, not code, so classification can
    # reproduce the rules in force on any historical date of service
    # (e.g. the ARPA 9815 UIO window) and statutory changes ship as data
    # updates, not releases. Global reference data, like the CMS tables.
    create_table :corvid_fmap_rules do |t|
      t.string :rule_key, null: false
      t.string :jurisdiction, null: false, default: "US"
      t.string :category, null: false
      t.decimal :fmap_percent, precision: 5, scale: 2
      t.string :statutory_citation, null: false

      # Match criteria. Empty arrays mean "any".
      t.jsonb :facility_authority_types, null: false, default: []
      t.jsonb :received_through_bases, null: false, default: []
      t.boolean :requires_aian, null: false, default: false
      t.boolean :requires_received_through, null: false, default: false
      t.string :coverage_group

      # A rule with no effective_on is dormant (e.g. the UIO parity rule
      # awaiting enactment): present as data, never in force.
      t.date :effective_on
      t.date :expires_on
      t.text :notes

      t.timestamps
    end

    add_index :corvid_fmap_rules, :rule_key, unique: true
    add_index :corvid_fmap_rules, [ :jurisdiction, :effective_on ]

    # The billing vehicle behind an encounter: what authority the facility
    # bills under, and on what basis it can claim the AIR outside its four
    # walls. Effective-dated because authority type can change (e.g. a
    # program moving from direct service to a 638 contract).
    create_table :corvid_facility_authorities do |t|
      t.string :tenant_identifier, null: false
      t.string :facility_identifier, null: false
      t.string :authority_type, null: false
      t.boolean :air_eligible, null: false, default: false
      t.string :four_walls_exception_basis
      t.string :service_area
      # Required: an undated authority must never read as held for all
      # history (a NULL start would classify a pre-contract date of
      # service at 100 percent). Open-ended is expires_on NULL only.
      t.date :effective_on, null: false
      t.date :expires_on

      t.timestamps
    end

    add_index :corvid_facility_authorities,
              [ :tenant_identifier, :facility_identifier ],
              name: "idx_corvid_facility_authorities_tenant_facility"

    # One row per classification. Immutable once a claim references it;
    # corrections append a superseding row so an audit packet can replay
    # exactly what was determined, from which rules, on which evidence.
    create_table :corvid_fmap_determinations do |t|
      t.string :tenant_identifier, null: false
      t.string :encounter_identifier, null: false
      t.string :person_identifier
      t.string :facility_identifier
      t.date :date_of_service, null: false
      t.string :jurisdiction, null: false

      t.string :category, null: false
      t.decimal :fmap_percent, precision: 5, scale: 2
      t.string :rule_key
      t.jsonb :rule_citations, null: false, default: []

      # Evidence chain: artifact refs (attestations, documents) the
      # determination rests on, plus the inputs that were asserted.
      t.jsonb :evidence_refs, null: false, default: []
      t.boolean :aian_verified, null: false, default: false
      t.string :received_through_basis
      t.string :coverage_group

      # The misclassification lens: what the encounter could have been
      # with full evidence, and what evidence is missing to get there.
      t.string :best_available_category
      t.string :best_available_rule_key
      t.jsonb :missing_evidence, null: false, default: []
      t.bigint :state_share_delta_cents

      # Why a determination is undetermined, or landed below the tier
      # the inputs suggested (no rules in force, no matching rule, an
      # unevidenced 100 percent). Null when a rule applied cleanly.
      t.string :determination_reason

      t.string :claim_reference
      t.bigint :superseded_by_id
      t.datetime :determined_at, null: false

      t.timestamps
    end

    add_index :corvid_fmap_determinations,
              [ :tenant_identifier, :encounter_identifier ],
              name: "idx_corvid_fmap_determinations_tenant_encounter"

    add_index :corvid_fmap_determinations,
              [ :tenant_identifier, :date_of_service ],
              name: "idx_corvid_fmap_determinations_tenant_dos"
  end
end
