# frozen_string_literal: true

module Corvid
  module Demo
    # Seeds the real CMS rate rows the MLR analyzer prices against, and
    # registers the PRC procedure/facility dictionary entries the overlay
    # demo needs.
    #
    # The PFS (CY2026 Montana locality 01) and OPPS (CY2026 national)
    # literals below are the same hand-verified real CMS Final Rule figures
    # used by the GM-6 MLR savings demo (corvid#472, see
    # docs/gm6_mlr_savings_methodology.md for citations). They are seeded
    # with real CMS release labels, so the analyzer returns
    # rate_source: :real / recovery_confidence: :clear — the MLR side of
    # every savings number is real, exactly as in #472. Only the billed
    # charges (in the synthetic FHIR dataset) are invented.
    #
    # Unlike #472, obligations here are sourced from stock FHIR rather than
    # an RPMS caret export — the analyzer/rate pipeline is unchanged.
    module CmsRateSeed
      MONTANA_LOCALITY = "01"
      PFS_EFFECTIVE_DATE = Date.new(2026, 1, 1)
      PFS_CONVERSION_FACTOR = 33.4009
      PFS_GPCI = { work: 1.000, pe: 1.000, mp: 0.998 }.freeze
      PFS_RELEASE_LABEL = "cms_pfs_cy2026_final_rule_mt01_handverified"

      # cpt => [description, work_rvu, non-facility pe_rvu, mp_rvu]
      PFS_CODES = {
        "99213" => [ "Office/outpatient visit, established patient, low complexity", 1.30, 1.46, 0.09 ],
        "99214" => [ "Office/outpatient visit, established patient, moderate complexity", 1.92, 2.00, 0.14 ],
        "99203" => [ "Office/outpatient visit, new patient, low complexity", 1.60, 1.76, 0.16 ],
        "12001" => [ "Simple repair of superficial wound(s), <= 2.5 cm", 0.82, 2.41, 0.18 ],
        "93000" => [ "Electrocardiogram, complete", 0.17, 0.27, 0.02 ]
      }.freeze

      OPPS_CALENDAR_YEAR = 2026
      OPPS_CONVERSION_FACTOR = 91.4150
      OPPS_WAGE_INDEX = 1.0
      OPPS_RELEASE_LABEL = "cms_opps_cy2026_final_rule"

      # ed-visit HCPCS => [apc_code, description, apc_relative_weight]
      OPPS_CODES = {
        "99283" => [ "5023", "Hospital outpatient ED visit, level 3 (moderate)", 3.0508 ],
        "99284" => [ "5024", "Hospital outpatient ED visit, level 4 (high)", 4.6634 ]
      }.freeze

      module_function

      # Idempotent: clears and reseeds the rows this demo owns.
      def seed!
        seed_pfs!
        seed_opps!
        register_dictionaries!
      end

      def seed_pfs!
        PFS_CODES.each do |cpt, (_desc, work, pe, mp)|
          Corvid::FeeScheduleEntry
            .where(cpt_code: cpt, locality: MONTANA_LOCALITY, effective_date: PFS_EFFECTIVE_DATE)
            .delete_all
          Corvid::FeeScheduleEntry.create!(
            cpt_code: cpt, locality: MONTANA_LOCALITY, effective_date: PFS_EFFECTIVE_DATE,
            work_rvu: work, pe_rvu: pe, mp_rvu: mp,
            work_gpci: PFS_GPCI[:work], pe_gpci: PFS_GPCI[:pe], mp_gpci: PFS_GPCI[:mp],
            conversion_factor: PFS_CONVERSION_FACTOR, release_label: PFS_RELEASE_LABEL
          )
        end
      end

      def seed_opps!
        OPPS_CODES.each do |_hcpcs, (apc, _desc, weight)|
          Corvid::OppsApcWeight.where(calendar_year: OPPS_CALENDAR_YEAR, apc_code: apc).delete_all
          Corvid::OppsApcWeight.create!(
            calendar_year: OPPS_CALENDAR_YEAR, apc_code: apc,
            relative_weight: weight, release_label: OPPS_RELEASE_LABEL
          )
        end
        Corvid::OppsConversionFactor.where(
          calendar_year: OPPS_CALENDAR_YEAR, locality: Corvid::OppsConversionFactor::NATIONAL_LOCALITY
        ).delete_all
        Corvid::OppsConversionFactor.create!(
          calendar_year: OPPS_CALENDAR_YEAR, locality: Corvid::OppsConversionFactor::NATIONAL_LOCALITY,
          conversion_factor: OPPS_CONVERSION_FACTOR, wage_index: OPPS_WAGE_INDEX,
          release_label: OPPS_RELEASE_LABEL
        )
      end

      # Register dictionary entries keyed by the billed code itself — stock
      # FHIR claim lines carry real CPT/HCPCS, so the obligation's
      # procedure_code IS the billing code (no RPMS shorthand to translate).
      def register_dictionaries!
        PFS_CODES.each do |cpt, (desc, *)|
          Corvid::PrcProcedureDictionary.register(cpt, hcpcs: cpt, description: desc)
        end
        OPPS_CODES.each do |hcpcs, (apc, desc, _weight)|
          Corvid::PrcProcedureDictionary.register(hcpcs, hcpcs: hcpcs, apc: apc, description: desc)
        end

        Corvid::Demo::FhirOverlayData.clinics.each do |clinic|
          Corvid::PrcFacilityDictionary.register(
            clinic.facility, name: clinic.name, city: clinic.city,
            state: clinic.state, zip: clinic.zip, locality: clinic.locality
          )
        end
      end
    end
  end
end
