# frozen_string_literal: true

module FhirAdapterContractFixtures
  module_function

  def patient_resource(id, family, given)
    {
      "resourceType" => "Patient",
      "id" => id,
      "birthDate" => "1980-01-01",
      "gender" => "female",
      "name" => [ { "family" => family, "given" => [ given ] } ],
      "identifier" => [ { "system" => "http://hl7.org/fhir/sid/us-ssn", "value" => "000-00-0001" } ],
      "extension" => [
        tribal_enrollment_extension,
        residency_extension,
        us_core_birthplace_extension
      ]
    }
  end

  def patient_resource_tribal_no_confidence(id, family, given)
    {
      "resourceType" => "Patient",
      "id" => id,
      "birthDate" => "1990-05-05",
      "gender" => "male",
      "name" => [ { "family" => family, "given" => [ given ] } ],
      "extension" => [ tribal_enrollment_extension_without_confidence ]
    }
  end

  def practitioner_resource(id, family, given)
    {
      "resourceType" => "Practitioner",
      "id" => id,
      "name" => [ { "family" => family, "given" => [ given ] } ],
      "identifier" => [ { "system" => "http://hl7.org/fhir/sid/us-npi", "value" => "0000000001" } ],
      "qualification" => [ { "code" => { "coding" => [ { "display" => "TEST SPECIALTY" } ] } } ]
    }
  end

  def service_request_resource(id, patient_id)
    {
      "resourceType" => "ServiceRequest",
      "id" => id,
      "status" => "active",
      "priority" => "routine",
      "subject" => { "reference" => "Patient/#{patient_id}" },
      "code" => { "text" => "TEST,CONTRACT SERVICE" }
    }
  end

  def coverage_resource(id, patient_id)
    {
      "resourceType" => "Coverage",
      "id" => id,
      "status" => "active",
      "beneficiary" => { "reference" => "Patient/#{patient_id}" },
      "type" => { "coding" => [ { "code" => "MCDSC" } ] },
      "payor" => [ { "display" => "TEST PAYER" } ],
      "subscriberId" => "TEST-POLICY-001",
      "period" => { "start" => "2026-01-01", "end" => "2026-12-31" }
    }
  end

  def care_team_resource(id, patient_id, practitioner_id)
    {
      "resourceType" => "CareTeam",
      "id" => id,
      "status" => "active",
      "name" => "TEST CARE TEAM",
      "subject" => { "reference" => "Patient/#{patient_id}" },
      "participant" => [
        {
          "member" => { "reference" => "Practitioner/#{practitioner_id}" },
          "role" => [ { "coding" => [ { "code" => "practitioner" } ] } ]
        }
      ]
    }
  end

  def claim_resource(id, patient_id)
    {
      "resourceType" => "Claim",
      "id" => id,
      "patient" => { "reference" => "Patient/#{patient_id}" },
      "item" => [ {
        "sequence" => 1,
        "productOrService" => {
          "coding" => [ { "system" => "http://www.ama-assn.org/go/cpt", "code" => "99213", "display" => "TEST VISIT" } ]
        },
        "net" => { "value" => 100.0, "currency" => "USD" }
      } ]
    }
  end

  def tribal_enrollment_extension
    {
      "url" => "https://lakeraven.com/fhir/StructureDefinition/tribal-enrollment",
      "extension" => [
        { "url" => "enrolled", "valueBoolean" => true },
        { "url" => "membershipNumber", "valueString" => "TEST-CONTRACT-001" },
        { "url" => "tribeName", "valueString" => "TEST TRIBE" },
        { "url" => "tribeCode", "valueString" => "TST" },
        { "url" => "memberStatus", "valueString" => "enrolled" },
        { "url" => "bloodQuantum", "valueDecimal" => 0.25 },
        { "url" => "confidence", "valueString" => "verified" }
      ]
    }
  end

  def tribal_enrollment_extension_without_confidence
    {
      "url" => "https://lakeraven.com/fhir/StructureDefinition/tribal-enrollment",
      "extension" => [
        { "url" => "enrolled", "valueBoolean" => true },
        { "url" => "membershipNumber", "valueString" => "TEST-CONTRACT-002" },
        { "url" => "tribeName", "valueString" => "TEST TRIBE" },
        { "url" => "tribeCode", "valueString" => "TST" }
      ]
    }
  end

  def residency_extension
    {
      "url" => "https://lakeraven.com/fhir/StructureDefinition/residency",
      "extension" => [
        { "url" => "onReservation", "valueBoolean" => true },
        { "url" => "serviceArea", "valueString" => "TEST AREA" }
      ]
    }
  end

  def us_core_birthplace_extension
    {
      "url" => "http://hl7.org/fhir/us/core/StructureDefinition/us-core-birthplace",
      "valueAddress" => {
        "city" => "TEST CITY",
        "state" => "WA"
      }
    }
  end
end

FHIR_ADAPTER_CONTRACT_FAIL_CLOSED_STUBS = {
  submit_claim: "Stock FHIR has no clearinghouse; submit_claim returns status unsupported",
  check_claim_status: "Stock FHIR has no remittance read; check_claim_status returns status unsupported",
  process_payment: "Stock FHIR has no payment rail; process_payment returns status unsupported",
  refund_payment: "Stock FHIR has no payment rail; refund_payment returns status unsupported"
}.freeze

FHIR_ADAPTER_CONTRACT_UNSUPPORTED = {
  store_text: "Stock FHIR has no vault; production must wire store_text separately",
  fetch_text: "Stock FHIR has no vault; production must wire fetch_text separately",
  dereference: "Stock FHIR has no vault; production must wire dereference separately",
  dereference_many: "Stock FHIR has no vault; production must wire dereference_many separately",
  create_obligation: "Stock FHIR cannot encumber CHS funds without a budget backend",
  release_obligation: "Stock FHIR has no obligation release API on Base/FhirAdapter",
  record_payment: "Stock FHIR has no obligation payment API on Base/FhirAdapter",
  update_obligation_status: "Stock FHIR has no obligation status API on Base/FhirAdapter"
}.freeze
