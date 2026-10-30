# frozen_string_literal: true

require "bigdecimal"

# Synthetic FHIR R4 resource hashes for ChargeBuilder specs. No real NPIs or names.
module Corvid::Rcm::FhirEncounterFactory
  module_function

  CPT = "http://www.ama-assn.org/go/cpt"
  HCPCS = "https://www.cms.gov/Medicare/Coding/HCPCSReleaseCodeSets"
  ICD10 = "http://hl7.org/fhir/sid/icd-10-cm"
  NPI = "http://hl7.org/fhir/sid/us-npi"
  ACT_CODE = "http://terminology.hl7.org/CodeSystem/v3-ActCode"
  LOCATION_PHYSICAL = "http://terminology.hl7.org/CodeSystem/location-physical-type"
  SNOMED = "http://snomed.info/sct"
  TELEPHONE_ENCOUNTER = "185317003"

  RENDERING_NPI = "1999999992"
  SERVICE_INSTANT = "2026-08-15T14:00:00-07:00"
  SERVICE_DATE = Date.new(2026, 8, 15)

  PHI_TRAP_NOTE = "SYNTH-PHI-TRAP DO NOT EMIT"

  def encounter(id: "enc-synth-1", status: "finished", class_code: "AMB", at_home: false,
                audio_only_type: false, diagnosis: [], **extra)
    resource = {
      "resourceType" => "Encounter",
      "id" => id,
      "status" => status,
      "class" => { "system" => ACT_CODE, "code" => class_code },
      "diagnosis" => diagnosis,
      "text" => { "div" => PHI_TRAP_NOTE }
    }.merge(extra)
    if at_home
      resource["location"] = [ {
        "location" => { "reference" => "Location/loc-synth-home" },
        "physicalType" => {
          "coding" => [ { "system" => LOCATION_PHYSICAL, "code" => "ho" } ]
        }
      } ]
    end
    if audio_only_type
      resource["type"] = [ {
        "coding" => [ { "system" => SNOMED, "code" => TELEPHONE_ENCOUNTER } ]
      } ]
    end
    resource
  end

  def encounter_diagnosis_ref(condition_id, rank: nil)
    entry = { "condition" => { "reference" => "Condition/#{condition_id}" } }
    entry["rank"] = rank unless rank.nil?
    entry
  end

  def procedure(id:, encounter_id:, code:, status: "completed", npi: RENDERING_NPI,
                performed_at: SERVICE_INSTANT, performed_end: nil, reason_condition_ids: [],
                note: PHI_TRAP_NOTE)
    performer_actor = if npi.nil?
                        { "reference" => "Practitioner/pr-synth" }
    else
                        { "identifier" => [ { "system" => NPI, "value" => npi } ] }
    end
    resource = {
      "resourceType" => "Procedure",
      "id" => id,
      "status" => status,
      "encounter" => { "reference" => "Encounter/#{encounter_id}" },
      "code" => {
        "coding" => [ { "system" => CPT, "code" => code } ]
      },
      "performer" => [ { "actor" => performer_actor } ],
      "note" => [ { "text" => note } ]
    }
    if performed_end
      resource["performedPeriod"] = { "start" => performed_at, "end" => performed_end }
    elsif !performed_at.nil?
      resource["performedDateTime"] = performed_at
    end
    unless reason_condition_ids.empty?
      resource["reasonReference"] = reason_condition_ids.map do |cid|
        { "reference" => "Condition/#{cid}" }
      end
    end
    resource
  end

  def condition(id:, icd10:, note: PHI_TRAP_NOTE)
    {
      "resourceType" => "Condition",
      "id" => id,
      "code" => {
        "coding" => [ { "system" => ICD10, "code" => icd10 } ]
      },
      "note" => [ { "text" => note } ]
    }
  end

  AUDIO_ONLY_MODIFIER_URL = "https://corvid.example/fhir/StructureDefinition/audio-only-modifier"

  def coverage(status: "active", identifier: "cov-synth-1", payer_identifier: "PAYER-SYNTH-01",
               audio_only_modifier: nil)
    resource = {
      "resourceType" => "Coverage",
      "status" => status,
      "identifier" => [ { "value" => identifier } ],
      "payor" => [ { "identifier" => { "value" => payer_identifier } } ],
      "subscriber" => {
        "name" => [ { "given" => [ "SYNTH-SUB-GIVEN" ], "family" => "SYNTH-SUB-FAMILY" } ],
        "birthDate" => "1988-04-02",
        "gender" => "female"
      }
    }
    if audio_only_modifier
      resource["extension"] = [ {
        "url" => AUDIO_ONLY_MODIFIER_URL,
        "valueCode" => audio_only_modifier
      } ]
    end
    resource
  end

  def flat_price(amount = BigDecimal("150.00"))
    ->(_code, _modifiers) { amount }
  end

  def price_map(map)
    ->(code, modifiers) { map.fetch([ code, Array(modifiers) ], map[code]) }
  end
end
