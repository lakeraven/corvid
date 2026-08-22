# frozen_string_literal: true

module Corvid
  module Demo
    # Reusable PRC governed-migration demo — SEED + ORCHESTRATION only.
    #
    # Stages a FULLY SYNTHETIC "Broken Rock" scenario (no real tribe, facility,
    # person, or PHI) and runs Corvid::GovernedMigration for each hero patient
    # through an INJECTED target. The governance — Data Governance Board consent
    # gate, minimum-necessary filter, audit Determination — is enforced by
    # GovernedMigration; this only stages the scenario and reports outcomes.
    #
    # Transport is injected. The default is the in-process StubMigrationTarget
    # so the flow runs offline; a host (e.g. corvid-saas) injects a real
    # transport (LakeravenEhrTarget) for a live relay. The seam is the whole
    # point: this demo is the reusable core, the vendor transport lives outside.
    #
    #   Corvid::Demo::Migration.run!                       # offline, stub target
    #   Corvid::Demo::Migration.run!(target: LakeravenEhrTarget.new(...))  # live
    module Migration
      DEFAULT_TENANT = "tnt_broken_rock_demo"
      FACILITY = "fac_broken_rock"

      # The types the Data Governance Board consents to release for hero_1.
      CONSENTED_TYPES = %w[Patient Condition Observation].freeze

      # Two synthetic hero patients (tokenized patient_ref). hero_1 is consented
      # and migrates; hero_2 has NO board consent and halts — the deny path is
      # what proves the sovereignty gate is real, not just trusted.
      HEROES = {
        "pt_broken_rock_hero_1" => {
          name: "Riverstone, Dawn (synthetic)",
          consented: true,
          entries: [
            { resource_type: "Patient",
              data: { "resourceType" => "Patient", "id" => "pt_broken_rock_hero_1",
                      "name" => [ { "family" => "Riverstone", "given" => [ "Dawn" ] } ] } },
            { resource_type: "Condition",
              data: { "resourceType" => "Condition", "code" => { "text" => "synthetic hypertension" } } },
            { resource_type: "Observation",
              data: { "resourceType" => "Observation", "valueString" => "synthetic BP 128/82" } }
          ]
        },
        "pt_broken_rock_hero_2" => {
          name: "Cedarwind, Marcus (synthetic)",
          consented: false,
          entries: [
            { resource_type: "Patient",
              data: { "resourceType" => "Patient", "id" => "pt_broken_rock_hero_2",
                      "name" => [ { "family" => "Cedarwind", "given" => [ "Marcus" ] } ] } },
            { resource_type: "Condition",
              data: { "resourceType" => "Condition", "code" => { "text" => "synthetic diabetes" } } }
          ]
        }
      }.freeze

      Outcome = Struct.new(:patient_ref, :name, :consented, :result, keyword_init: true)

      module_function

      # Idempotent: find-or-create the two hero cases. No PHI at rest beyond the
      # optional synthetic cached display name. Returns the hero patient_refs.
      def seed!(tenant: DEFAULT_TENANT)
        Corvid.with_tenant(tenant) do
          HEROES.each do |patient_ref, spec|
            Corvid::Case.find_or_create_by!(
              tenant_identifier: tenant,
              facility_identifier: FACILITY,
              patient_identifier: patient_ref
            ) do |c|
              c.patient_name_cached = spec[:name]
              c.status = "active"
              c.lifecycle_status = "intake"
              c.intake_at = Time.current
            end
          end
        end
        HEROES.keys
      end

      # Run the governed migration for each hero through the injected target.
      # Seeds first so run! is usable standalone. Returns Array<Outcome>.
      def run!(tenant: DEFAULT_TENANT, target: StubMigrationTarget.new)
        seed!(tenant: tenant)
        Corvid.with_tenant(tenant) do
          HEROES.map do |patient_ref, spec|
            kase = Corvid::Case.find_by!(tenant_identifier: tenant, patient_identifier: patient_ref)
            result = Corvid::GovernedMigration.new(target: target).run(
              case_record: kase,
              consent: board_consent_for(spec),
              bundle: bundle_for(patient_ref, spec)
            )
            Outcome.new(patient_ref: patient_ref, name: spec[:name], consented: spec[:consented], result: result)
          end
        end
      end

      # Clear the seeded rows (dependent: :destroy also removes their audit
      # Determinations). Returns the number of hero cases removed.
      def reset!(tenant: DEFAULT_TENANT)
        Corvid.with_tenant(tenant) do
          cases = Corvid::Case.where(tenant_identifier: tenant, patient_identifier: HEROES.keys)
          count = cases.count
          cases.destroy_all
          count
        end
      end

      def bundle_for(patient_ref, spec)
        Corvid::MigrationBundle.new(patient_ref: patient_ref, entries: spec[:entries])
      end

      def board_consent_for(spec)
        return nil unless spec[:consented]

        Corvid::Migration::BoardConsent.new(
          granted: true,
          consented_resource_types: CONSENTED_TYPES,
          actor_identifier: "dgb_board_001"
        )
      end
    end
  end
end
