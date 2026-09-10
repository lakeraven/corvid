# frozen_string_literal: true

require "minitest/autorun"
require "corvid"
require "corvid/rcm"
require_relative "claim_factory"

# The FHIR R4-shaped inputs, including the bridge from the shape the existing
# generic FhirAdapter already produces.
class Corvid::Rcm::ClaimTest < Minitest::Test
  Factory = Corvid::Rcm::ClaimFactory

  # Phase 0 has to be runnable with no Rails and no test database. Asserted in
  # a clean subprocess, because the rest of the suite loads Rails into this one.
  def test_the_rcm_module_runs_in_a_process_with_no_rails_and_no_database
    lib = File.expand_path("../../../lib", __dir__)
    script = <<~RUBY
      require "corvid/rcm"
      abort("ActiveRecord was loaded") if defined?(ActiveRecord::Base)
      abort("Rails was loaded") if defined?(Rails)
      claim = Corvid::Rcm::Claim.new(identifier: "CLM-X", patient_identifier: "pt_x")
      abort("scrub produced nothing") if Corvid::Rcm::Scrubber.new.scrub(claim).findings.empty?
      abort("no fixtures") if Corvid::Rcm::FixtureClearinghouseClient.new.fetch_remittances.empty?
    RUBY

    assert system(RbConfig.ruby, "-I", lib, "-e", script),
           "corvid/rcm must load and run standalone"
  end

  def test_a_claim_totals_its_billed_lines
    claim = Factory.claim(items: [ Factory.line(billed_amount: 200.00),
                                   Factory.line(sequence: 2, billed_amount: 45.00) ])

    assert_in_delta 245.00, claim.total_billed, 0.001
    assert_equal Factory::SERVICE_DATE, claim.earliest_service_date
  end

  def test_a_claim_reads_its_payer_from_the_coverage
    assert_equal "EXPAYER01", Factory.claim.payer_identifier
    assert_nil Factory.claim(coverage: nil).payer_identifier
  end

  def test_a_three_character_diagnosis_is_a_category_header
    assert Corvid::Rcm::Diagnosis.new(sequence: 1, code: "F32").category_header?
    refute Corvid::Rcm::Diagnosis.new(sequence: 1, code: "F32.9").category_header?
    assert_equal "F", Corvid::Rcm::Diagnosis.new(sequence: 1, code: "F32.9").chapter_letter
  end

  def test_telehealth_modalities_are_recognised
    assert Factory.line(encounter_modality: :telehealth_patient_home).telehealth?
    assert Factory.line(encounter_modality: :audio_only).telehealth?
    refute Factory.line(encounter_modality: :in_person).telehealth?
  end

  # -- the bridge from the adapter layer -------------------------------------

  def test_it_builds_a_line_from_the_shape_the_fhir_adapter_already_emits
    reference = Corvid::ClaimLineReference.new(
      claim_identifier: "fhir-claim-1",
      patient_identifier: "pt_0001",
      provider_identifier: Factory::RENDERING_NPI,
      procedure_code: "90837",
      procedure_display: "Psychotherapy, 60 minutes",
      serviced_date: Factory::SERVICE_DATE,
      billed_amount: BigDecimal("200.00"),
      currency: "USD",
      sequence: 1
    )

    line = Corvid::Rcm::ClaimLine.from_claim_line_reference(
      reference,
      place_of_service: "11",
      encounter_modality: :in_person,
      documented_minutes: 55
    )

    assert_equal "90837", line.procedure_code
    assert_equal BigDecimal("200.00"), line.billed_amount
    assert_equal Factory::SERVICE_DATE, line.serviced_date
    assert_equal :in_person, line.encounter_modality
  end

  def test_a_line_bridged_without_encounter_facts_blocks_at_scrub_time
    reference = Corvid::ClaimLineReference.new(
      claim_identifier: "fhir-claim-2", patient_identifier: "pt_0001",
      provider_identifier: Factory::RENDERING_NPI, procedure_code: "90837",
      procedure_display: nil, serviced_date: Factory::SERVICE_DATE,
      billed_amount: BigDecimal("200.00"), currency: "USD", sequence: 1
    )
    line = Corvid::Rcm::ClaimLine.from_claim_line_reference(reference)
    result = Corvid::Rcm::Scrubber.new.scrub(Factory.claim(items: [ line ]), as_of: Factory::TODAY)

    refute result.submittable?
    assert_includes result.blocked_by, :place_of_service_matches_encounter_modality
  end

  # -- history ---------------------------------------------------------------

  def test_history_finds_duplicates_on_patient_date_and_procedure
    history = Factory.history(Factory.prior_service(claim_identifier: "CLM-1900"))

    assert_equal 1, history.duplicates_of(patient_identifier: "pt_0001", procedure_code: "90837",
                                          serviced_date: Factory::SERVICE_DATE).length
    assert_empty history.duplicates_of(patient_identifier: "pt_0002", procedure_code: "90837",
                                       serviced_date: Factory::SERVICE_DATE)
  end

  def test_history_can_scope_a_lookup_to_one_rendering_provider_and_window
    history = Factory.history(
      Factory.prior_service(procedure_code: "90791", serviced_date: Date.new(2026, 2, 10)),
      Factory.prior_service(procedure_code: "90791", rendering_provider_npi: "1555555550",
                            serviced_date: Date.new(2026, 3, 10))
    )

    scoped = history.services_for(patient_identifier: "pt_0001", procedure_code: "90791",
                                  rendering_provider_npi: Factory::RENDERING_NPI,
                                  on_or_after: Date.new(2026, 1, 1))
    assert_equal 1, scoped.length
    assert_empty history.services_for(patient_identifier: "pt_0001", procedure_code: "90791",
                                      on_or_after: Date.new(2026, 6, 1))
  end
end
