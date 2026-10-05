# frozen_string_literal: true

require "corvid/rcm"

# Builds claim-shaped inputs for the RCM tests. The baseline claim is
# deliberately CLEAN — it passes every v1 scrub rule — so each test can break
# exactly one thing and assert that exactly one rule fires. All data is
# synthetic: invented NPIs with valid check digits, an invented payer, an
# invented clinic.
module Corvid::Rcm::ClaimFactory
  module_function

  BILLING_NPI = "1999999992"
  RENDERING_NPI = "1299999999"
  SERVICE_DATE = Date.new(2026, 8, 15)
  # Far enough after the service date to be realistic, early enough in the
  # filing window that the timely-filing rules stay quiet unless a test moves it.
  TODAY = Date.new(2026, 8, 20)

  def coverage(**overrides)
    Corvid::Rcm::Coverage.new(**{
      identifier: "cov_0001",
      payer_identifier: "EXPAYER01",
      payer_name: "Example Health Plan",
      status: "active",
      relationship: "self",
      subscriber_identifier: "MBR0001",
      subscriber_given_name: "ALPHA",
      subscriber_family_name: "EXAMPLEPATIENT",
      subscriber_birth_date: Date.new(1988, 4, 2),
      subscriber_gender: "F",
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 12, 31),
      timely_filing_days: 365,
      audio_only_modifier: "93"
    }.merge(overrides))
  end

  def line(**overrides)
    Corvid::Rcm::ClaimLine.new(**{
      sequence: 1,
      procedure_code: "90837",
      modifiers: [],
      place_of_service: "11",
      encounter_modality: :in_person,
      serviced_date: SERVICE_DATE,
      billed_amount: 200.00,
      currency: "USD",
      units: 1,
      documented_minutes: 55,
      diagnosis_sequences: [ 1 ]
    }.merge(overrides))
  end

  def diagnosis(code = "F41.1", sequence: 1)
    Corvid::Rcm::Diagnosis.new(sequence: sequence, code: code)
  end

  def claim(**overrides)
    Corvid::Rcm::Claim.new(**{
      identifier: "CLM-2001",
      tenant_identifier: "tnt_example",
      claim_type: "professional",
      patient_identifier: "pt_0001",
      patient_given_name: "ALPHA",
      patient_family_name: "EXAMPLEPATIENT",
      patient_birth_date: Date.new(1988, 4, 2),
      patient_gender: "F",
      billing_provider_npi: BILLING_NPI,
      billing_provider_tax_id: "990000001",
      rendering_provider_npi: RENDERING_NPI,
      rendering_provider_taxonomy: "101YM0800X",
      coverage: coverage,
      diagnoses: [ diagnosis ],
      items: [ line ],
      created: Date.new(2026, 8, 16)
    }.merge(overrides))
  end

  # A claim whose single line is replaced by one built from the overrides.
  def claim_with_line(**line_overrides)
    claim(items: [ line(**line_overrides) ])
  end

  def history(*services)
    Corvid::Rcm::ClaimHistory.new(services)
  end

  def prior_service(**overrides)
    Corvid::Rcm::PriorService.new(**{
      claim_identifier: "CLM-1999",
      patient_identifier: "pt_0001",
      rendering_provider_npi: RENDERING_NPI,
      procedure_code: "90837",
      serviced_date: SERVICE_DATE
    }.merge(overrides))
  end
end
