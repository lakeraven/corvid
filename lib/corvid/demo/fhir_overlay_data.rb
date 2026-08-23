# frozen_string_literal: true

require "corvid/adapters/fhir_adapter"

module Corvid
  module Demo
    # Synthetic stock-FHIR R4 datasets for the multi-clinic overlay demo.
    #
    # Everything here is invented — synthetic clinic names, synthetic patient
    # names/ids, synthetic vendors, synthetic dollar amounts. No real
    # clinic/consortium/place/person/vendor appears. The two clinics stand in
    # for a consortium of purchased/referred-care programs running DIFFERENT
    # source EHRs. Ingest is stock FHIR R4 and EHR-agnostic: the source-EHR
    # labels are deliberately generic ("Ambulatory EHR A/B") and no real EHR
    # product is named — any conformant FHIR R4 EHR maps the same way.
    #
    # Resources emitted per clinic (all standard R4):
    #   Patient  — with a Lakeraven tribal-enrollment extension (FHIR/US Core
    #              has no native tribal-enrollment concept) + residency ext.
    #   Coverage — payer-of-last-resort context (tribal program).
    #   Claim    — purchased/referred-care billed line items. Each Claim.item
    #              carries a real CPT/HCPCS code, service date, and billed
    #              net amount — the stock-FHIR shape PRC ingest maps to a
    #              PrcObligation.
    module FhirOverlayData
      EXT = Corvid::Adapters::FhirAdapter::EXTENSION_BASE_URL
      TRIBAL_EXT = "#{EXT}/tribal-enrollment"
      RESIDENCY_EXT = "#{EXT}/residency"
      CPT_SYSTEM = "http://www.ama-assn.org/go/cpt"
      HCPCS_SYSTEM = "https://bluebutton.cms.gov/resources/codesystem/hcpcs"

      Clinic = Struct.new(
        :tenant, :facility, :name, :city, :state, :zip, :locality,
        :source_ehr_label, :resources,
        keyword_init: true
      )

      module_function

      # Both synthetic clinics, each a self-contained FHIR dataset.
      def clinics
        [ broken_rock, tallgrass ]
      end

      # --- Clinic A -------------------------------------------------------
      # Source EHR type: a generic ambulatory EHR exporting stock FHIR R4. No
      # real EHR product is named; the ingest below touches no vendor-specific
      # field — it reads plain R4.
      def broken_rock
        Clinic.new(
          tenant: "tnt_broken_rock", facility: "fac_broken_rock",
          name: "Broken Rock Clinic", city: "Cedar Bend", state: "MT",
          zip: "59000", locality: "01",
          source_ehr_label: "Ambulatory EHR A (stock FHIR R4 export)",
          resources: [
            patient("pt_br_001", "OVERLAY", "PATIENT A-ONE", "1972-04-11", "F", "BR-1001"),
            patient("pt_br_002", "OVERLAY", "PATIENT A-TWO", "1988-09-02", "M", "BR-1002"),
            patient("pt_br_003", "OVERLAY", "PATIENT A-THREE", "1965-01-27", "F", "BR-1003"),
            coverage("cov_br_001", "pt_br_001"),
            coverage("cov_br_002", "pt_br_002"),
            coverage("cov_br_003", "pt_br_003"),
            # billed line items (CPT/HCPCS, service date, synthetic billed net)
            claim("clm_br_1", "pt_br_001", "VEND-BR-01", "Broken Rock Specialty Assoc",
                  "99213", "2026-02-10", 240.00, CPT_SYSTEM, "Office visit, established, low"),
            claim("clm_br_2", "pt_br_001", "VEND-BR-02", "Cedar Bend Imaging",
                  "99214", "2026-03-15", 360.00, CPT_SYSTEM, "Office visit, established, moderate"),
            claim("clm_br_3", "pt_br_002", "VEND-BR-01", "Broken Rock Specialty Assoc",
                  "99203", "2026-04-01", 320.00, CPT_SYSTEM, "Office visit, new, low"),
            claim("clm_br_4", "pt_br_002", "VEND-BR-03", "Cedar Bend Surgical",
                  "12001", "2026-05-20", 420.00, CPT_SYSTEM, "Simple wound repair <= 2.5cm"),
            claim("clm_br_5", "pt_br_003", "VEND-BR-04", "Regional Hospital Outpatient",
                  "99283", "2026-06-05", 900.00, HCPCS_SYSTEM, "Emergency dept visit, level 3")
          ]
        )
      end

      # --- Clinic B -------------------------------------------------------
      # Source EHR type: a DIFFERENT generic ambulatory EHR exporting stock
      # FHIR R4. No real EHR product is named. Same generic ingest path.
      def tallgrass
        Clinic.new(
          tenant: "tnt_tallgrass", facility: "fac_tallgrass",
          name: "Tallgrass Clinic", city: "Willow Flats", state: "MT",
          zip: "59001", locality: "01",
          source_ehr_label: "Ambulatory EHR B (stock FHIR R4 export)",
          resources: [
            patient("pt_tg_001", "OVERLAY", "PATIENT B-ONE", "1979-07-19", "M", "TG-2001"),
            patient("pt_tg_002", "OVERLAY", "PATIENT B-TWO", "1991-11-30", "F", "TG-2002"),
            patient("pt_tg_003", "OVERLAY", "PATIENT B-THREE", "1958-03-05", "M", "TG-2003"),
            coverage("cov_tg_001", "pt_tg_001"),
            coverage("cov_tg_002", "pt_tg_002"),
            coverage("cov_tg_003", "pt_tg_003"),
            claim("clm_tg_1", "pt_tg_001", "VEND-TG-01", "Willow Flats Cardiology",
                  "99213", "2026-02-20", 250.00, CPT_SYSTEM, "Office visit, established, low"),
            claim("clm_tg_2", "pt_tg_001", "VEND-TG-02", "Willow Flats Cardiology",
                  "93000", "2026-03-10", 120.00, CPT_SYSTEM, "Electrocardiogram, complete"),
            claim("clm_tg_3", "pt_tg_002", "VEND-TG-01", "Willow Flats Cardiology",
                  "99214", "2026-04-12", 380.00, CPT_SYSTEM, "Office visit, established, moderate"),
            claim("clm_tg_4", "pt_tg_002", "VEND-TG-03", "Prairie Family Medicine",
                  "99203", "2026-05-08", 300.00, CPT_SYSTEM, "Office visit, new, low"),
            claim("clm_tg_5", "pt_tg_003", "VEND-TG-04", "Regional Hospital Outpatient",
                  "99284", "2026-07-01", 1200.00, HCPCS_SYSTEM, "Emergency dept visit, level 4")
          ]
        )
      end

      # --- FHIR resource builders (plain R4) ------------------------------

      def patient(id, family, given, birth_date, gender, membership_number)
        {
          "resourceType" => "Patient",
          "id" => id,
          "name" => [ { "family" => family, "given" => [ given ] } ],
          "birthDate" => birth_date,
          "gender" => gender,
          "extension" => [
            {
              "url" => TRIBAL_EXT,
              "extension" => [
                { "url" => "enrolled", "valueBoolean" => true },
                { "url" => "membershipNumber", "valueString" => membership_number },
                { "url" => "tribeName", "valueString" => "Example Tribe" },
                { "url" => "tribeCode", "valueString" => "EXT" },
                { "url" => "confidence", "valueString" => "verified" }
              ]
            },
            {
              "url" => RESIDENCY_EXT,
              "extension" => [
                { "url" => "onReservation", "valueBoolean" => true },
                { "url" => "serviceArea", "valueString" => "example_service_area" }
              ]
            }
          ]
        }
      end

      def coverage(id, patient_id)
        {
          "resourceType" => "Coverage",
          "id" => id,
          "status" => "active",
          "type" => { "coding" => [ { "system" => "http://terminology.hl7.org/CodeSystem/v3-ActCode", "code" => "TRIB" } ] },
          "beneficiary" => { "reference" => "Patient/#{patient_id}" },
          "subscriberId" => "TRIB-#{patient_id}",
          "payor" => [ { "display" => "Example Tribal Health Program" } ],
          "period" => { "start" => "2026-01-01", "end" => "2026-12-31" }
        }
      end

      def claim(id, patient_id, provider_id, provider_display, code, serviced_date, billed, system, display)
        {
          "resourceType" => "Claim",
          "id" => id,
          "status" => "active",
          "use" => "claim",
          "patient" => { "reference" => "Patient/#{patient_id}" },
          "created" => serviced_date,
          "provider" => { "display" => provider_display, "identifier" => { "value" => provider_id } },
          "item" => [
            {
              "sequence" => 1,
              "productOrService" => { "coding" => [ { "system" => system, "code" => code, "display" => display } ] },
              "servicedDate" => serviced_date,
              "net" => { "value" => billed, "currency" => "USD" }
            }
          ],
          "total" => { "value" => billed, "currency" => "USD" }
        }
      end
    end
  end
end
