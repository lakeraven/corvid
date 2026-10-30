# frozen_string_literal: true

require "minitest/autorun"
require "bigdecimal"
require "corvid/rcm/charge_builder"
require_relative "fhir_encounter_factory"

class Corvid::Rcm::ChargeBuilderTest < Minitest::Test
  Factory = Corvid::Rcm::FhirEncounterFactory
  Builder = Corvid::Rcm::ChargeBuilder

  def build(encounter:, procedures: [], conditions: [], coverage: Factory.coverage, price_list: Factory.flat_price)
    Builder.build(
      encounter: encounter,
      procedures: procedures,
      conditions: conditions,
      coverage: coverage,
      price_list: price_list
    )
  end

  def problem_codes(charge_set)
    charge_set.problems.map(&:code)
  end

  def assert_single_problem(charge_set, code, reference: nil)
    assert_equal 1, charge_set.problems.length, charge_set.problems.inspect
    problem = charge_set.problems.first
    assert_equal code, problem.code
    if reference.nil?
      assert_nil problem.reference
    else
      assert_equal reference, problem.reference
    end
  end

  def assert_problems_include(charge_set, code, reference: nil)
    match = charge_set.problems.find do |problem|
      problem.code == code && (reference.nil? || problem.reference == reference)
    end
    refute_nil match, "expected #{code.inspect} #{reference.inspect} in #{charge_set.problems.inspect}"
  end

  def refute_problems_include(charge_set, code, reference: nil)
    charge_set.problems.each do |problem|
      next unless problem.code == code
      next unless reference.nil? || problem.reference == reference

      flunk("unexpected #{code.inspect} #{reference.inspect} in #{charge_set.problems.inspect}")
    end
  end

  def diagnosis_tuples(charge_set)
    charge_set.diagnoses.map { |d| [ d.sequence, d.code ] }
  end

  def problem_tuples(charge_set)
    charge_set.problems.map { |p| [ p.code, p.reference ] }
  end

  def assert_diagnoses_exact(charge_set, expected)
    assert_equal expected, diagnosis_tuples(charge_set), charge_set.diagnoses.inspect
  end

  def assert_problems_exact(charge_set, expected)
    assert_equal expected, problem_tuples(charge_set), charge_set.problems.inspect
  end

  def refute_price_list_called
    ->(_code, _modifiers) { flunk("price_list must not be called") }
  end

  # -- value object contracts -------------------------------------------------

  def test_charge_set_charge_problem_and_nested_collections_are_frozen
    enc = Factory.encounter
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90834")
    cond = Factory.condition(id: "c1", icd10: "F41.1")
    charge_set = build(
      encounter: enc,
      procedures: [ proc ],
      conditions: [ cond ],
      price_list: Factory.flat_price(BigDecimal("120.00"))
    )

    assert charge_set.frozen?
    assert charge_set.lines.frozen?
    assert charge_set.diagnoses.frozen?
    assert charge_set.problems.frozen?
    charge_set.problems.each { |problem| assert problem.frozen? }
  end

  # -- encounter gate ---------------------------------------------------------

  def test_non_finished_encounter_yields_encounter_not_finished_and_skips_price_list
    enc = Factory.encounter(status: "in-progress")
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90834")

    charge_set = build(
      encounter: enc,
      procedures: [ proc ],
      conditions: [ Factory.condition(id: "c1", icd10: "F41.1") ],
      price_list: refute_price_list_called
    )

    assert_equal "Encounter/enc-synth-1", charge_set.encounter_reference
    assert_empty charge_set.lines
    assert_empty charge_set.diagnoses
    assert_single_problem(charge_set, :encounter_not_finished)
  end

  def test_planned_or_nil_encounter_status_also_fails_the_gate
    [ "planned", nil ].each do |status|
      enc = Factory.encounter(status: status)
      charge_set = build(encounter: enc, price_list: refute_price_list_called)

      assert_empty charge_set.lines
      assert_single_problem(charge_set, :encounter_not_finished)
    end
  end

  def test_unfinished_encounter_acceptance_scenario
    enc = Factory.encounter(status: "in-progress")
    charge_set = build(
      encounter: enc,
      procedures: [ Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90837") ],
      price_list: refute_price_list_called
    )

    assert_empty charge_set.lines
    assert_equal [ :encounter_not_finished ], problem_codes(charge_set)
  end

  # -- encounter modality -----------------------------------------------------

  def test_unknown_or_missing_encounter_class_fails_closed
    enc = Factory.encounter(class_code: "IMP")
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90834")
    charge_set = build(
      encounter: enc,
      procedures: [ proc ],
      conditions: [ Factory.condition(id: "c1", icd10: "F41.1") ]
    )

    assert_empty charge_set.lines
    assert_single_problem(charge_set, :encounter_modality_unknown)
  end

  def test_in_person_90834_acceptance_scenario
    enc = Factory.encounter(class_code: "AMB")
    cond = Factory.condition(id: "c1", icd10: "F41.1")
    proc = Factory.procedure(
      id: "p1", encounter_id: enc.fetch("id"), code: "90834",
      reason_condition_ids: [ "c1" ]
    )
    amount = BigDecimal("135.00")
    charge_set = build(
      encounter: enc,
      procedures: [ proc ],
      conditions: [ cond ],
      price_list: Factory.flat_price(amount)
    )

    assert_empty charge_set.problems
    assert_equal 1, charge_set.lines.length
    line = charge_set.lines.first
    assert_equal 1, line.sequence
    assert_equal "90834", line.procedure_code
    assert_equal [], line.modifiers
    assert_equal "11", line.place_of_service
    assert_equal :in_person, line.encounter_modality
    assert_equal Factory::SERVICE_DATE, line.serviced_date
    assert_equal amount, line.billed_amount
    assert_equal "USD", line.currency
    assert_equal 1, line.units
    assert_equal [ 1 ], line.diagnosis_sequences
    refute line.telehealth?
    assert_equal Factory::RENDERING_NPI, charge_set.rendering_provider_npi
  end

  def test_telehealth_video_90837_at_home_acceptance_scenario
    enc = Factory.encounter(class_code: "VR", at_home: true)
    cond = Factory.condition(id: "c1", icd10: "F41.1")
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90837",
                             reason_condition_ids: [ "c1" ])
    charge_set = build(encounter: enc, procedures: [ proc ], conditions: [ cond ])

    line = charge_set.lines.first
    assert_equal "10", line.place_of_service
    assert_equal [ "95" ], line.modifiers
    assert_equal :telehealth_patient_home, line.encounter_modality
    assert line.telehealth?
    refute_includes line.modifiers, "93"
  end

  def test_telehealth_video_not_at_home_uses_pos_02
    enc = Factory.encounter(class_code: "VR", at_home: false)
    cond = Factory.condition(id: "c1", icd10: "F41.1")
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90837",
                             reason_condition_ids: [ "c1" ])
    charge_set = build(encounter: enc, procedures: [ proc ], conditions: [ cond ])

    line = charge_set.lines.first
    assert_equal "02", line.place_of_service
    assert_equal [ "95" ], line.modifiers
    assert_equal :telehealth_other, line.encounter_modality
  end

  def test_audio_only_uses_payer_modifier_at_home_acceptance_scenario
    enc = Factory.encounter(class_code: "VR", at_home: true, audio_only_type: true)
    cond = Factory.condition(id: "c1", icd10: "F41.1")
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90837",
                             reason_condition_ids: [ "c1" ])
    charge_set = build(
      encounter: enc,
      procedures: [ proc ],
      conditions: [ cond ],
      coverage: Factory.coverage(audio_only_modifier: "FQ")
    )

    line = charge_set.lines.first
    assert_equal :audio_only, line.encounter_modality
    assert_equal "10", line.place_of_service
    assert_equal [ "FQ" ], line.modifiers
    refute_includes line.modifiers, "95"
  end

  def test_group_90853_in_person_acceptance_scenario
    enc = Factory.encounter(class_code: "AMB")
    cond = Factory.condition(id: "c1", icd10: "F41.1")
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90853",
                             reason_condition_ids: [ "c1" ])
    charge_set = build(encounter: enc, procedures: [ proc ], conditions: [ cond ])

    line = charge_set.lines.first
    assert_equal "90853", line.procedure_code
    assert_equal :in_person, line.encounter_modality
    assert_equal "11", line.place_of_service
  end

  # -- procedures -------------------------------------------------------------

  def test_procedure_for_another_encounter_is_a_problem_not_a_line
    enc = Factory.encounter
    proc = Factory.procedure(id: "p-wrong", encounter_id: "other-enc", code: "90834")
    charge_set = build(
      encounter: enc,
      procedures: [ proc ],
      conditions: [ Factory.condition(id: "c1", icd10: "F41.1") ]
    )

    assert_empty charge_set.lines
    assert_single_problem(charge_set, :procedure_not_in_encounter, reference: "Procedure/p-wrong")
  end

  def test_incomplete_procedure_yields_procedure_not_completed
    enc = Factory.encounter
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90834", status: "in-progress")
    charge_set = build(
      encounter: enc,
      procedures: [ proc ],
      conditions: [ Factory.condition(id: "c1", icd10: "F41.1") ]
    )

    assert_empty charge_set.lines
    assert_single_problem(charge_set, :procedure_not_completed, reference: "Procedure/p1")
  end

  def test_unknown_procedure_code_acceptance_scenario
    enc = Factory.encounter
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90999")
    charge_set = build(
      encounter: enc,
      procedures: [ proc ],
      conditions: [ Factory.condition(id: "c1", icd10: "F41.1") ]
    )

    assert_empty charge_set.lines
    assert_single_problem(charge_set, :code_not_in_charge_set, reference: "Procedure/p1")
  end

  def test_serviced_date_uses_calendar_date_from_offset_datetime
    enc = Factory.encounter
    cond = Factory.condition(id: "c1", icd10: "F41.1")
    proc = Factory.procedure(
      id: "p1", encounter_id: enc.fetch("id"), code: "90834",
      performed_at: "2026-08-15T23:30:00-07:00",
      reason_condition_ids: [ "c1" ]
    )
    charge_set = build(encounter: enc, procedures: [ proc ], conditions: [ cond ])

    assert_equal Date.new(2026, 8, 15), charge_set.lines.first.serviced_date
  end

  def test_missing_serviced_date_yields_serviced_date_missing
    enc = Factory.encounter
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90834",
                             performed_at: nil)
    charge_set = build(
      encounter: enc,
      procedures: [ proc ],
      conditions: [ Factory.condition(id: "c1", icd10: "F41.1") ]
    )

    assert_empty charge_set.lines
    assert_single_problem(charge_set, :serviced_date_missing, reference: "Procedure/p1")
  end

  def test_documented_minutes_from_performed_period
    enc = Factory.encounter
    cond = Factory.condition(id: "c1", icd10: "F41.1")
    proc = Factory.procedure(
      id: "p1", encounter_id: enc.fetch("id"), code: "90837",
      performed_at: "2026-08-15T14:00:00-07:00",
      performed_end: "2026-08-15T14:53:00-07:00",
      reason_condition_ids: [ "c1" ]
    )
    charge_set = build(encounter: enc, procedures: [ proc ], conditions: [ cond ])

    assert_equal 53, charge_set.lines.first.documented_minutes
    assert_equal 1, charge_set.lines.first.units
  end

  def test_billable_procedures_receive_sequential_line_numbers
    enc = Factory.encounter
    c1 = Factory.condition(id: "c1", icd10: "F41.1")
    p1 = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90834",
                           reason_condition_ids: [ "c1" ])
    p2 = Factory.procedure(id: "p2", encounter_id: enc.fetch("id"), code: "90837",
                           reason_condition_ids: [ "c1" ])
    charge_set = build(encounter: enc, procedures: [ p1, p2 ], conditions: [ c1 ])

    assert_equal [ 1, 2 ], charge_set.lines.map(&:sequence)
  end

  # -- pricing ----------------------------------------------------------------

  def test_missing_price_acceptance_scenario
    enc = Factory.encounter
    cond = Factory.condition(id: "c1", icd10: "F41.1")
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90834",
                             reason_condition_ids: [ "c1" ])
    charge_set = build(
      encounter: enc,
      procedures: [ proc ],
      conditions: [ cond ],
      price_list: ->(_code, _modifiers) { nil }
    )

    assert_empty charge_set.lines
    assert_single_problem(charge_set, :no_price, reference: "Procedure/p1")
  end

  def test_invalid_price_types_yield_invalid_price_without_a_line
    enc = Factory.encounter
    cond = Factory.condition(id: "c1", icd10: "F41.1")
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90834",
                             reason_condition_ids: [ "c1" ])

    [ 150.0, -BigDecimal("1"), BigDecimal("NaN"), "150.00" ].each do |bad_amount|
      charge_set = build(
        encounter: enc,
        procedures: [ proc ],
        conditions: [ cond ],
        price_list: ->(_code, _modifiers) { bad_amount }
      )
      assert_empty charge_set.lines, "expected no line for #{bad_amount.inspect}"
      assert_includes problem_codes(charge_set), :invalid_price
    end
  end

  def test_price_list_receives_procedure_code_and_line_modifiers
    enc = Factory.encounter(class_code: "VR", at_home: true)
    cond = Factory.condition(id: "c1", icd10: "F41.1")
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90837",
                             reason_condition_ids: [ "c1" ])
    seen = []
    price_list = lambda do |code, modifiers|
      seen << [ code, modifiers ]
      BigDecimal("200.00")
    end
    build(encounter: enc, procedures: [ proc ], conditions: [ cond ], price_list: price_list)

    assert_equal [ [ "90837", [ "95" ] ] ], seen
  end

  # -- rendering provider -----------------------------------------------------

  def test_rendering_provider_missing_still_builds_lines
    enc = Factory.encounter
    cond = Factory.condition(id: "c1", icd10: "F41.1")
    proc = Factory.procedure(
      id: "p1", encounter_id: enc.fetch("id"), code: "90834",
      performers: [ Factory.untyped_identifier_performer(npi: Factory::RENDERING_NPI) ],
      reason_condition_ids: [ "c1" ]
    )
    charge_set = build(encounter: enc, procedures: [ proc ], conditions: [ cond ])

    assert_equal 1, charge_set.lines.length
    assert_nil charge_set.rendering_provider_npi
    assert_includes problem_codes(charge_set), :rendering_provider_missing
  end

  def test_two_rendering_npis_yield_multiple_rendering_providers
    enc = Factory.encounter
    cond = Factory.condition(id: "c1", icd10: "F41.1")
    p1 = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90834",
                           npi: "1999999992", reason_condition_ids: [ "c1" ])
    p2 = Factory.procedure(id: "p2", encounter_id: enc.fetch("id"), code: "90837",
                           npi: "1299999999", reason_condition_ids: [ "c1" ])
    charge_set = build(encounter: enc, procedures: [ p1, p2 ], conditions: [ cond ])

    assert_equal 2, charge_set.lines.length
    assert_nil charge_set.rendering_provider_npi
    assert_includes problem_codes(charge_set), :multiple_rendering_providers
  end

  # -- diagnoses --------------------------------------------------------------

  def test_diagnosis_fallback_by_encounter_rank_acceptance_scenario
    enc = Factory.encounter(
      diagnosis: [
        Factory.encounter_diagnosis_ref("c-secondary", rank: 2),
        Factory.encounter_diagnosis_ref("c-primary", rank: 1),
        Factory.encounter_diagnosis_ref("c-unranked")
      ]
    )
    c_primary = Factory.condition(id: "c-primary", icd10: "F41.1")
    c_secondary = Factory.condition(id: "c-secondary", icd10: "F32.9")
    c_unranked = Factory.condition(id: "c-unranked", icd10: "F33.0")
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90834")
    charge_set = build(
      encounter: enc,
      procedures: [ proc ],
      conditions: [ c_secondary, c_primary, c_unranked ]
    )

    assert_diagnoses_exact(charge_set, [ [ 1, "F41.1" ] ])
    assert_equal [ 1 ], charge_set.lines.first.diagnosis_sequences
  end

  def test_line_diagnosis_pointers_follow_procedure_reason_reference_order
    enc = Factory.encounter
    c1 = Factory.condition(id: "c1", icd10: "F41.1")
    c2 = Factory.condition(id: "c2", icd10: "F32.9")
    proc = Factory.procedure(
      id: "p1", encounter_id: enc.fetch("id"), code: "90834",
      reason_condition_ids: [ "c2", "c1" ]
    )
    charge_set = build(encounter: enc, procedures: [ proc ], conditions: [ c1, c2 ])

    assert_equal [ "F32.9", "F41.1" ], charge_set.diagnoses.map(&:code)
    assert_equal [ 1, 2 ], charge_set.lines.first.diagnosis_sequences
  end

  def test_unresolved_condition_reference_yields_diagnosis_unresolved
    enc = Factory.encounter
    proc = Factory.procedure(
      id: "p1", encounter_id: enc.fetch("id"), code: "90834",
      reason_condition_ids: [ "missing" ]
    )
    charge_set = build(
      encounter: enc,
      procedures: [ proc ],
      conditions: [ Factory.condition(id: "c1", icd10: "F41.1") ]
    )

    assert_includes problem_codes(charge_set), :diagnosis_unresolved
    problem = charge_set.problems.find { |p| p.code == :diagnosis_unresolved }
    assert_equal "Condition/missing", problem.reference
  end

  def test_line_with_no_resolvable_diagnosis_yields_no_diagnosis
    enc = Factory.encounter(diagnosis: [])
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90834")
    charge_set = build(encounter: enc, procedures: [ proc ], conditions: [])

    assert_empty charge_set.lines
    assert_single_problem(charge_set, :no_diagnosis, reference: "Procedure/p1")
  end

  # -- coverage ---------------------------------------------------------------

  def test_coverage_is_built_from_fhir_without_subscriber_phi
    enc = Factory.encounter
    cond = Factory.condition(id: "c1", icd10: "F41.1")
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90834",
                             reason_condition_ids: [ "c1" ])
    charge_set = build(
      encounter: enc,
      procedures: [ proc ],
      conditions: [ cond ],
      coverage: Factory.coverage
    )

    cov = charge_set.coverage
    refute_nil cov
    assert_equal "PAYER-SYNTH-01", cov.payer_identifier
    assert_equal "active", cov.status
    assert_nil cov.subscriber_given_name
    assert_nil cov.subscriber_family_name
    assert_nil cov.subscriber_birth_date
    assert_nil cov.subscriber_gender
  end

  def test_nil_coverage_input_yields_nil_coverage_without_a_problem
    enc = Factory.encounter
    cond = Factory.condition(id: "c1", icd10: "F41.1")
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90834",
                             reason_condition_ids: [ "c1" ])
    charge_set = build(encounter: enc, procedures: [ proc ], conditions: [ cond ], coverage: nil)

    assert_nil charge_set.coverage
    assert_empty charge_set.problems
  end

  # -- issue #748 rules D1–D11 (synthetic fixtures only) ----------------------

  def test_d1_every_diagnosis_reference_must_resolve_without_encounter_fallback_shortcuts
    enc = Factory.encounter
    c1 = Factory.condition(id: "c1", icd10: "F41.1")
    mixed_proc = Factory.procedure(
      id: "p-mixed", encounter_id: enc.fetch("id"), code: "90834",
      reason_condition_ids: [ "c1", "cX" ]
    )
    mixed = build(encounter: enc, procedures: [ mixed_proc ], conditions: [ c1 ])
    assert_empty mixed.lines
    assert_problems_include(mixed, :diagnosis_unresolved, reference: "Condition/cX")
    assert_problems_include(mixed, :no_diagnosis, reference: "Procedure/p-mixed")

    enc_fallback = Factory.encounter(
      diagnosis: [
        Factory.encounter_diagnosis_ref("c-missing", rank: 1),
        Factory.encounter_diagnosis_ref("c-secondary", rank: 2)
      ]
    )
    c_secondary = Factory.condition(id: "c-secondary", icd10: "F32.9")
    fallback_proc = Factory.procedure(id: "p-fallback", encounter_id: enc_fallback.fetch("id"), code: "90834")
    fallback = build(
      encounter: enc_fallback,
      procedures: [ fallback_proc ],
      conditions: [ c_secondary ]
    )
    assert_empty fallback.lines
    assert_problems_include(fallback, :diagnosis_unresolved, reference: "Condition/c-missing")
    assert_problems_include(fallback, :no_diagnosis, reference: "Procedure/p-fallback")
    refute_equal [ 1 ], fallback.lines.map(&:diagnosis_sequences).flatten

    enc_principal = Factory.encounter(
      diagnosis: [ Factory.encounter_diagnosis_ref("c1", rank: 1) ]
    )
    blocked_proc = Factory.procedure(
      id: "p-blocked", encounter_id: enc_principal.fetch("id"), code: "90834",
      reason_condition_ids: [ "c-missing" ]
    )
    blocked = build(
      encounter: enc_principal,
      procedures: [ blocked_proc ],
      conditions: [ c1 ]
    )
    assert_empty blocked.lines
    assert_problems_include(blocked, :diagnosis_unresolved, reference: "Condition/c-missing")
    assert_problems_include(blocked, :no_diagnosis, reference: "Procedure/p-blocked")
  end

  def test_d2_non_billable_condition_verification_status_blocks_lines
    enc = Factory.encounter
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90834",
                             reason_condition_ids: [ "c-refuted" ])

    %w[refuted entered-in-error unconfirmed].each do |status|
      cond = Factory.condition(id: "c-refuted", icd10: "F41.1", verification_status: status)
      charge_set = build(encounter: enc, procedures: [ proc ], conditions: [ cond ])
      assert_empty charge_set.lines
      assert_problems_include(charge_set, :diagnosis_not_billable, reference: "Condition/c-refuted")
      assert_problems_include(charge_set, :no_diagnosis, reference: "Procedure/p1")
    end

    %w[confirmed provisional differential].each do |status|
      cond = Factory.condition(id: "c-ok", icd10: "F41.1", verification_status: status)
      charge_set = build(
        encounter: enc,
        procedures: [ Factory.procedure(id: "p-ok", encounter_id: enc.fetch("id"), code: "90834",
                                      reason_condition_ids: [ "c-ok" ]) ],
        conditions: [ cond ]
      )
      assert_equal 1, charge_set.lines.length
      refute_problems_include(charge_set, :diagnosis_not_billable)
    end

    cond_absent = Factory.condition(id: "c-absent", icd10: "F41.1")
    charge_set = build(
      encounter: enc,
      procedures: [ Factory.procedure(id: "p-absent", encounter_id: enc.fetch("id"), code: "90834",
                                    reason_condition_ids: [ "c-absent" ]) ],
      conditions: [ cond_absent ]
    )
    assert_equal 1, charge_set.lines.length
  end

  def test_d3_encounter_diagnosis_rank_must_be_positive_integer_when_present
    enc = Factory.encounter(
      diagnosis: [ Factory.encounter_diagnosis_ref("c1", rank: "1") ]
    )
    c1 = Factory.condition(id: "c1", icd10: "F41.1")
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90834")
    charge_set = build(encounter: enc, procedures: [ proc ], conditions: [ c1 ])
    assert_empty charge_set.lines
    assert_problems_include(charge_set, :diagnosis_rank_invalid, reference: "Condition/c1")
    assert_problems_include(charge_set, :no_diagnosis, reference: "Procedure/p1")

    [ 0, -1 ].each do |bad_rank|
      enc_bad = Factory.encounter(
        diagnosis: [ Factory.encounter_diagnosis_ref("c-bad", rank: bad_rank) ]
      )
      cond = Factory.condition(id: "c-bad", icd10: "F32.9")
      bad_set = build(
        encounter: enc_bad,
        procedures: [ Factory.procedure(id: "p-bad", encounter_id: enc_bad.fetch("id"), code: "90834") ],
        conditions: [ cond ]
      )
      assert_empty bad_set.lines
      assert_problems_include(bad_set, :diagnosis_rank_invalid, reference: "Condition/c-bad")
    end

    enc_sort = Factory.encounter(
      diagnosis: [
        Factory.encounter_diagnosis_ref("c-unranked"),
        Factory.encounter_diagnosis_ref("c-ranked", rank: 1)
      ]
    )
    c_ranked = Factory.condition(id: "c-ranked", icd10: "F41.1")
    c_unranked = Factory.condition(id: "c-unranked", icd10: "F32.9")
    sorted = build(
      encounter: enc_sort,
      procedures: [ Factory.procedure(id: "p-sort", encounter_id: enc_sort.fetch("id"), code: "90834") ],
      conditions: [ c_unranked, c_ranked ]
    )
    assert_diagnoses_exact(sorted, [ [ 1, "F41.1" ] ])
    assert_equal 1, sorted.lines.length
  end

  def test_d4_diagnoses_deduplicate_by_icd10_and_cap_at_four_per_line
    enc = Factory.encounter
    c_a = Factory.condition(id: "c-a", icd10: "F41.1")
    c_b = Factory.condition(id: "c-b", icd10: "F41.1")
    dedupe_proc = Factory.procedure(
      id: "p-dedupe", encounter_id: enc.fetch("id"), code: "90834",
      reason_condition_ids: [ "c-a", "c-b" ]
    )
    deduped = build(encounter: enc, procedures: [ dedupe_proc ], conditions: [ c_a, c_b ])
    assert_equal 1, deduped.diagnoses.length
    assert_equal [ 1 ], deduped.lines.first.diagnosis_sequences

    codes = %w[F41.1 F32.9 F33.0 F34.1 F40.0]
    conditions = codes.each_with_index.map do |code, index|
      Factory.condition(id: "c#{index}", icd10: code)
    end
    too_many_proc = Factory.procedure(
      id: "p-many", encounter_id: enc.fetch("id"), code: "90837",
      reason_condition_ids: conditions.map { |c| c.fetch("id") }
    )
    too_many = build(encounter: enc, procedures: [ too_many_proc ], conditions: conditions)
    assert_empty too_many.lines
    assert_problems_include(too_many, :too_many_diagnoses, reference: "Procedure/p-many")
  end

  def test_d5_rendering_provider_counts_practitioner_performer_npi_only
    enc = Factory.encounter
    c1 = Factory.condition(id: "c1", icd10: "F41.1")

    org_only = Factory.procedure(
      id: "p-org", encounter_id: enc.fetch("id"), code: "90834",
      performers: [ Factory.organization_performer(npi: Factory::RENDERING_NPI) ],
      reason_condition_ids: [ "c1" ]
    )
    org_set = build(encounter: enc, procedures: [ org_only ], conditions: [ c1 ])
    assert_equal 1, org_set.lines.length
    assert_nil org_set.rendering_provider_npi
    assert_problems_include(org_set, :rendering_provider_missing, reference: "Procedure/p-org")

    ref_practitioner = Factory.procedure(
      id: "p-ref", encounter_id: enc.fetch("id"), code: "90834",
      performers: [ Factory.practitioner_reference_performer(npi: Factory::RENDERING_NPI) ],
      reason_condition_ids: [ "c1" ]
    )
    ref_set = build(encounter: enc, procedures: [ ref_practitioner ], conditions: [ c1 ])
    assert_equal Factory::RENDERING_NPI, ref_set.rendering_provider_npi

    dual = Factory.procedure(
      id: "p-dual", encounter_id: enc.fetch("id"), code: "90834",
      performers: [
        Factory.practitioner_performer(npi: Factory::RENDERING_NPI),
        Factory.practitioner_performer(npi: Factory::SECOND_RENDERING_NPI)
      ],
      reason_condition_ids: [ "c1" ]
    )
    dual_set = build(encounter: enc, procedures: [ dual ], conditions: [ c1 ])
    assert_equal 1, dual_set.lines.length
    assert_nil dual_set.rendering_provider_npi
    assert_problems_include(dual_set, :multiple_rendering_providers)

    non_npi = Factory.procedure(
      id: "p-non-npi", encounter_id: enc.fetch("id"), code: "90834", npi: nil,
      performers: [ {
        "actor" => {
          "identifier" => [ { "system" => "http://example.org/local-id", "value" => "LOCAL-1" } ]
        }
      } ],
      reason_condition_ids: [ "c1" ]
    )
    non_npi_set = build(encounter: enc, procedures: [ non_npi ], conditions: [ c1 ])
    assert_problems_include(non_npi_set, :rendering_provider_missing, reference: "Procedure/p-non-npi")
  end

  def test_d6_contradictory_or_unknown_encounter_modality_fails_closed
    enc = Factory.encounter(class_code: "AMB", audio_only_type: true)
    proc = Factory.procedure(
      id: "p-amb-phone", encounter_id: enc.fetch("id"), code: "90834",
      reason_condition_ids: [ "c1" ]
    )
    amb_phone = build(
      encounter: enc,
      procedures: [ proc ],
      conditions: [ Factory.condition(id: "c1", icd10: "F41.1") ]
    )
    assert_empty amb_phone.lines
    assert_equal [ :encounter_modality_unknown ], problem_codes(amb_phone)

    enc_home = Factory.encounter(class_code: "AMB", at_home: true)
    amb_home = build(
      encounter: enc_home,
      procedures: [ Factory.procedure(id: "p-amb-home", encounter_id: enc_home.fetch("id"), code: "90834",
                                      reason_condition_ids: [ "c1" ]) ],
      conditions: [ Factory.condition(id: "c1", icd10: "F41.1") ]
    )
    assert_empty amb_home.lines
    assert_equal [ :encounter_modality_unknown ], problem_codes(amb_home)

    enc_bad_system = Factory.encounter(class_code: "VR", class_system: "http://example.org/local-act")
    bad_system = build(
      encounter: enc_bad_system,
      procedures: [ Factory.procedure(id: "p-bad-class", encounter_id: enc_bad_system.fetch("id"),
                                    code: "90834", reason_condition_ids: [ "c1" ]) ],
      conditions: [ Factory.condition(id: "c1", icd10: "F41.1") ]
    )
    assert_empty bad_system.lines
    assert_equal [ :encounter_modality_unknown ], problem_codes(bad_system)
  end

  def test_d7_audio_only_defaults_and_video_pos_by_location_physical_type
    c1 = Factory.condition(id: "c1", icd10: "F41.1")

    enc_home = Factory.encounter(class_code: "VR", at_home: true, audio_only_type: true)
    home_default = build(
      encounter: enc_home,
      procedures: [ Factory.procedure(id: "p-audio-home", encounter_id: enc_home.fetch("id"), code: "90837",
                                      reason_condition_ids: [ "c1" ]) ],
      conditions: [ c1 ]
    )
    home_line = home_default.lines.first
    assert_equal "10", home_line.place_of_service
    assert_equal [ "93" ], home_line.modifiers

    enc_away = Factory.encounter(class_code: "VR", at_home: false, audio_only_type: true)
    away_default = build(
      encounter: enc_away,
      procedures: [ Factory.procedure(id: "p-audio-away", encounter_id: enc_away.fetch("id"), code: "90837",
                                      reason_condition_ids: [ "c1" ]) ],
      conditions: [ c1 ]
    )
    away_line = away_default.lines.first
    assert_equal "02", away_line.place_of_service
    assert_equal [ "93" ], away_line.modifiers

    blank_override = build(
      encounter: enc_home,
      procedures: [ Factory.procedure(id: "p-blank-mod", encounter_id: enc_home.fetch("id"), code: "90837",
                                      reason_condition_ids: [ "c1" ]) ],
      conditions: [ c1 ],
      coverage: Factory.coverage(audio_only_modifier: "   ")
    )
    assert_equal [ "93" ], blank_override.lines.first.modifiers

    enc_room = Factory.encounter(class_code: "VR", location_physical_type: "ro")
    video_room = build(
      encounter: enc_room,
      procedures: [ Factory.procedure(id: "p-video-room", encounter_id: enc_room.fetch("id"), code: "90837",
                                      reason_condition_ids: [ "c1" ]) ],
      conditions: [ c1 ]
    )
    room_line = video_room.lines.first
    assert_equal "02", room_line.place_of_service
    assert_equal [ "95" ], room_line.modifiers
  end

  def test_d8_charge_set_enforces_icd10_cm_and_cpt_hcpcs_procedure_systems
    enc = Factory.encounter
    snomed_only = Factory.condition(id: "c-snomed", snomed_code: "48694002")
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90834",
                             reason_condition_ids: [ "c-snomed" ])
    unresolved = build(encounter: enc, procedures: [ proc ], conditions: [ snomed_only ])
    assert_empty unresolved.lines
    assert_problems_include(unresolved, :diagnosis_unresolved, reference: "Condition/c-snomed")

    local_proc = Factory.procedure(
      id: "p-local", encounter_id: enc.fetch("id"), code: "90834",
      code_system: "http://example.org/local-codes",
      reason_condition_ids: [ "c1" ]
    )
    local = build(
      encounter: enc,
      procedures: [ local_proc ],
      conditions: [ Factory.condition(id: "c1", icd10: "F41.1") ]
    )
    assert_empty local.lines
    assert_problems_include(local, :code_not_in_charge_set, reference: "Procedure/p-local")
  end

  def test_d9_serviced_date_uses_period_start_and_rejects_malformed_datetimes
    enc = Factory.encounter
    c1 = Factory.condition(id: "c1", icd10: "F41.1")
    period_proc = Factory.procedure(
      id: "p-period", encounter_id: enc.fetch("id"), code: "90837",
      performed_at: "2026-08-15T23:30:00-07:00",
      performed_end: "2026-08-16T00:20:00-07:00",
      reason_condition_ids: [ "c1" ]
    )
    period_set = build(encounter: enc, procedures: [ period_proc ], conditions: [ c1 ])
    line = period_set.lines.first
    assert_equal Date.new(2026, 8, 15), line.serviced_date
    assert_equal 50, line.documented_minutes

    %w[2026-08-15Tnonsense 2026-13-01].each do |bad_instant|
      bad_proc = Factory.procedure(
        id: "p-bad-date", encounter_id: enc.fetch("id"), code: "90834",
        performed_at: bad_instant, reason_condition_ids: [ "c1" ]
      )
      bad_set = build(encounter: enc, procedures: [ bad_proc ], conditions: [ c1 ])
      assert_empty bad_set.lines
      assert_problems_include(bad_set, :serviced_date_missing, reference: "Procedure/p-bad-date")
    end
  end

  def test_d10_duplicate_procedure_id_emits_one_line_and_duplicate_procedure_problem
    enc = Factory.encounter
    c1 = Factory.condition(id: "c1", icd10: "F41.1")
    proc = Factory.procedure(id: "p-dup", encounter_id: enc.fetch("id"), code: "90834",
                             reason_condition_ids: [ "c1" ])
    charge_set = build(encounter: enc, procedures: [ proc, proc.dup ], conditions: [ c1 ])

    assert_equal 1, charge_set.lines.length
    assert_problems_include(charge_set, :duplicate_procedure, reference: "Procedure/p-dup")
  end

  def test_d11_coverage_status_and_reference_without_member_identifier_in_inspect
    enc = Factory.encounter
    c1 = Factory.condition(id: "c1", icd10: "F41.1")
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90834",
                             reason_condition_ids: [ "c1" ])
    member_id = "MEMBER-SYNTH-999"
    charge_set = build(
      encounter: enc,
      procedures: [ proc ],
      conditions: [ c1 ],
      coverage: Factory.coverage(id: "cov-synth-1", status: "cancelled", member_id: member_id)
    )

    cov = charge_set.coverage
    refute_nil cov
    assert_equal "cancelled", cov.status
    assert_equal "Coverage/cov-synth-1", cov.identifier
    refute_includes charge_set.inspect, member_id
  end

  # -- issue #748 rules E1–E7 (review round 2; synthetic fixtures only) ------

  def test_e1_claim_diagnoses_come_only_from_billed_lines
    enc = Factory.encounter(diagnosis: [])
    c_a = Factory.condition(id: "cA", icd10: "F43.10")
    c_b = Factory.condition(id: "cB", icd10: "F41.1")
    p_a = Factory.procedure(
      id: "pA", encounter_id: enc.fetch("id"), code: "90791",
      reason_condition_ids: [ "cA" ]
    )
    p_b = Factory.procedure(
      id: "pB", encounter_id: enc.fetch("id"), code: "90834",
      reason_condition_ids: [ "cB" ]
    )
    case_a = build(
      encounter: enc,
      procedures: [ p_a, p_b ],
      conditions: [ c_a, c_b ],
      price_list: Factory.price_map(
        "90791" => nil,
        "90834" => BigDecimal("120.00")
      )
    )
    assert_equal 1, case_a.lines.length
    assert_equal "90834", case_a.lines.first.procedure_code
    assert_equal [ 1 ], case_a.lines.first.diagnosis_sequences
    assert_diagnoses_exact(case_a, [ [ 1, "F41.1" ] ])
    assert_problems_exact(case_a, [ [ :no_price, "Procedure/pA" ] ])

    c1 = Factory.condition(id: "c1", icd10: "F41.1")
    c2 = Factory.condition(id: "c2", icd10: "F32.9")
    p_a_mixed = Factory.procedure(
      id: "pA-mixed", encounter_id: enc.fetch("id"), code: "90834",
      reason_condition_ids: [ "c1", "cX" ]
    )
    p_b_ok = Factory.procedure(
      id: "pB-ok", encounter_id: enc.fetch("id"), code: "90837",
      reason_condition_ids: [ "c2" ]
    )
    case_b = build(
      encounter: enc,
      procedures: [ p_a_mixed, p_b_ok ],
      conditions: [ c1, c2 ]
    )
    assert_equal 1, case_b.lines.length
    assert_equal "90837", case_b.lines.first.procedure_code
    assert_equal [ 1 ], case_b.lines.first.diagnosis_sequences
    assert_diagnoses_exact(case_b, [ [ 1, "F32.9" ] ])
    assert_problems_exact(case_b, [
      [ :diagnosis_unresolved, "Condition/cX" ],
      [ :no_diagnosis, "Procedure/pA-mixed" ]
    ])

    codes = %w[F41.1 F32.9 F33.0 F34.1 F40.0]
    five_conds = codes.each_with_index.map { |code, i| Factory.condition(id: "c#{i + 1}", icd10: code) }
    c6 = Factory.condition(id: "c6", icd10: "F42.0")
    p_a_many = Factory.procedure(
      id: "pA-many", encounter_id: enc.fetch("id"), code: "90834",
      reason_condition_ids: five_conds.map { |c| c.fetch("id") }
    )
    p_b_six = Factory.procedure(
      id: "pB-six", encounter_id: enc.fetch("id"), code: "90837",
      reason_condition_ids: [ "c6" ]
    )
    case_c = build(
      encounter: enc,
      procedures: [ p_a_many, p_b_six ],
      conditions: five_conds + [ c6 ]
    )
    assert_equal 1, case_c.lines.length
    assert_equal "90837", case_c.lines.first.procedure_code
    assert_equal [ 1 ], case_c.lines.first.diagnosis_sequences
    assert_diagnoses_exact(case_c, [ [ 1, "F42.0" ] ])
    assert_problems_exact(case_c, [ [ :too_many_diagnoses, "Procedure/pA-many" ] ])
  end

  def test_e2_rendering_provider_actor_reference_or_practitioner_type_only
    enc = Factory.encounter
    c1 = Factory.condition(id: "c1", icd10: "F41.1")

    untyped = Factory.procedure(
      id: "p-untyped", encounter_id: enc.fetch("id"), code: "90834",
      performers: [ Factory.untyped_identifier_performer ],
      reason_condition_ids: [ "c1" ]
    )
    untyped_set = build(encounter: enc, procedures: [ untyped ], conditions: [ c1 ])
    assert_equal 1, untyped_set.lines.length
    assert_nil untyped_set.rendering_provider_npi
    assert_problems_exact(untyped_set, [ [ :rendering_provider_missing, "Procedure/p-untyped" ] ])

    org_ref = Factory.procedure(
      id: "p-org-ref", encounter_id: enc.fetch("id"), code: "90834",
      performers: [ {
        "actor" => {
          "type" => "Practitioner",
          "reference" => "Organization/o1",
          "identifier" => [ { "system" => Factory::NPI, "value" => Factory::RENDERING_NPI } ]
        }
      } ],
      reason_condition_ids: [ "c1" ]
    )
    org_ref_set = build(encounter: enc, procedures: [ org_ref ], conditions: [ c1 ])
    assert_equal 1, org_ref_set.lines.length
    assert_nil org_ref_set.rendering_provider_npi
    assert_problems_exact(org_ref_set, [ [ :rendering_provider_missing, "Procedure/p-org-ref" ] ])

    typed = Factory.procedure(
      id: "p-typed", encounter_id: enc.fetch("id"), code: "90834",
      reason_condition_ids: [ "c1" ]
    )
    typed_set = build(encounter: enc, procedures: [ typed ], conditions: [ c1 ])
    assert_equal Factory::RENDERING_NPI, typed_set.rendering_provider_npi
    assert_empty typed_set.problems
  end

  def test_e3_condition_verification_status_gates_billable_diagnoses
    enc = Factory.encounter
    base_proc = lambda do |cond_id|
      Factory.procedure(
        id: "p-#{cond_id}", encounter_id: enc.fetch("id"), code: "90834",
        reason_condition_ids: [ cond_id ]
      )
    end

    cond_absent = Factory.condition(id: "c-absent", icd10: "F41.1")
    absent_set = build(
      encounter: enc,
      procedures: [ base_proc.call("c-absent") ],
      conditions: [ cond_absent ]
    )
    assert_equal 1, absent_set.lines.length
    assert_diagnoses_exact(absent_set, [ [ 1, "F41.1" ] ])
    assert_empty absent_set.problems

    %w[confirmed provisional differential].each do |status|
      cid = "c-#{status}"
      cond = Factory.condition(id: cid, icd10: "F41.1", verification_status: status)
      charge_set = build(
        encounter: enc,
        procedures: [ base_proc.call(cid) ],
        conditions: [ cond ]
      )
      assert_equal 1, charge_set.lines.length, status
      assert_diagnoses_exact(charge_set, [ [ 1, "F41.1" ] ])
      assert_empty charge_set.problems
    end

    %w[refuted entered-in-error unconfirmed bogus-status].each do |status|
      cid = "c-bad-#{status.tr('-', '_')}"
      cond = Factory.condition(id: cid, icd10: "F41.1", verification_status: status)
      charge_set = build(
        encounter: enc,
        procedures: [ base_proc.call(cid) ],
        conditions: [ cond ]
      )
      assert_empty charge_set.lines
      assert_empty charge_set.diagnoses
      assert_problems_exact(charge_set, [
        [ :diagnosis_not_billable, "Condition/#{cid}" ],
        [ :no_diagnosis, "Procedure/p-#{cid}" ]
      ])
    end

    cond_wrong_system = Factory.condition(
      id: "c-wrong-sys", icd10: "F41.1",
      verification_status: "confirmed", verification_system: "http://example.org/local-ver"
    )
    wrong_system = build(
      encounter: enc,
      procedures: [ base_proc.call("c-wrong-sys") ],
      conditions: [ cond_wrong_system ]
    )
    assert_empty wrong_system.lines
    assert_empty wrong_system.diagnoses
    assert_problems_exact(wrong_system, [
      [ :diagnosis_not_billable, "Condition/c-wrong-sys" ],
      [ :no_diagnosis, "Procedure/p-c-wrong-sys" ]
    ])
  end

  def test_e4_fallback_pins_encounter_diagnosis_rules
    enc_unresolved = Factory.encounter(
      diagnosis: [
        Factory.encounter_diagnosis_ref("c1", rank: 1),
        Factory.encounter_diagnosis_ref("cX", rank: 2)
      ]
    )
    c1 = Factory.condition(id: "c1", icd10: "F41.1")
    fallback_proc = Factory.procedure(id: "p-fallback", encounter_id: enc_unresolved.fetch("id"), code: "90834")
    unresolved_set = build(
      encounter: enc_unresolved,
      procedures: [ fallback_proc ],
      conditions: [ c1 ]
    )
    assert_empty unresolved_set.lines
    assert_empty unresolved_set.diagnoses
    assert_problems_exact(unresolved_set, [
      [ :diagnosis_unresolved, "Condition/cX" ],
      [ :no_diagnosis, "Procedure/p-fallback" ]
    ])

    enc_bad_rank = Factory.encounter(
      diagnosis: [
        Factory.encounter_diagnosis_ref("c1", rank: "1"),
        Factory.encounter_diagnosis_ref("c2", rank: 2)
      ]
    )
    c2 = Factory.condition(id: "c2", icd10: "F32.9")
    rank_proc = Factory.procedure(id: "p-rank", encounter_id: enc_bad_rank.fetch("id"), code: "90834")
    bad_rank_set = build(
      encounter: enc_bad_rank,
      procedures: [ rank_proc ],
      conditions: [ c1, c2 ]
    )
    assert_empty bad_rank_set.lines
    assert_empty bad_rank_set.diagnoses
    assert_problems_exact(bad_rank_set, [
      [ :diagnosis_rank_invalid, "Condition/c1" ],
      [ :no_diagnosis, "Procedure/p-rank" ]
    ])
  end

  def test_e5_units_stay_one_for_long_90837_session
    enc = Factory.encounter
    c1 = Factory.condition(id: "c1", icd10: "F41.1")
    proc = Factory.procedure(
      id: "p1", encounter_id: enc.fetch("id"), code: "90837",
      performed_at: "2026-08-15T14:00:00-07:00",
      performed_end: "2026-08-15T15:40:00-07:00",
      reason_condition_ids: [ "c1" ]
    )
    charge_set = build(encounter: enc, procedures: [ proc ], conditions: [ c1 ])

    assert_equal 1, charge_set.lines.length
    line = charge_set.lines.first
    assert_equal 1, line.units
    assert_equal 100, line.documented_minutes
    assert_empty charge_set.problems
  end

  def test_e6_encounter_modality_terminology_systems_are_strict
    c1 = Factory.condition(id: "c1", icd10: "F41.1")

    enc_wrong_home = Factory.encounter(
      class_code: "VR",
      location_physical_type: "ho",
      location_physical_system: "http://example.org/not-location-physical-type"
    )
    wrong_home = build(
      encounter: enc_wrong_home,
      procedures: [ Factory.procedure(id: "p-vr-ho", encounter_id: enc_wrong_home.fetch("id"), code: "90837",
                                        reason_condition_ids: [ "c1" ]) ],
      conditions: [ c1 ]
    )
    assert_equal 1, wrong_home.lines.length
    home_line = wrong_home.lines.first
    assert_equal "02", home_line.place_of_service
    assert_equal [ "95" ], home_line.modifiers
    assert_equal :telehealth_other, home_line.encounter_modality
    assert_empty wrong_home.problems

    enc_wrong_phone = Factory.encounter(
      class_code: "VR",
      at_home: true,
      audio_only_type: true,
      telephone_type_system: "http://example.org/not-snomed"
    )
    wrong_phone = build(
      encounter: enc_wrong_phone,
      procedures: [ Factory.procedure(id: "p-vr-type", encounter_id: enc_wrong_phone.fetch("id"), code: "90837",
                                        reason_condition_ids: [ "c1" ]) ],
      conditions: [ c1 ]
    )
    assert_equal 1, wrong_phone.lines.length
    phone_line = wrong_phone.lines.first
    assert_equal "10", phone_line.place_of_service
    assert_equal [ "95" ], phone_line.modifiers
    assert_equal :telehealth_patient_home, phone_line.encounter_modality
    refute_includes phone_line.modifiers, "93"
    assert_empty wrong_phone.problems
  end

  def test_e7_procedure_without_id_is_procedure_missing_id
    enc = Factory.encounter
    c1 = Factory.condition(id: "c1", icd10: "F41.1")
    proc = Factory.procedure(
      id: nil, encounter_id: enc.fetch("id"), code: "90834",
      reason_condition_ids: [ "c1" ]
    )
    charge_set = build(encounter: enc, procedures: [ proc, proc.dup ], conditions: [ c1 ])

    assert_empty charge_set.lines
    assert_empty charge_set.diagnoses
    assert_problems_exact(charge_set, [ [ :procedure_missing_id, nil ] ])
  end

  # -- issue #748 rules G1–G10 (review round 3; synthetic fixtures only) ------

  def test_g1_coverage_payer_must_be_organization
    trap_id = "MRN-SYNTH-12345"
    enc = Factory.encounter
    c1 = Factory.condition(id: "c1", icd10: "F41.1")
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90834",
                             reason_condition_ids: [ "c1" ])
    patient_payor = [ {
      "reference" => "Patient/pat-synth-selfpay",
      "identifier" => { "value" => trap_id }
    } ]
    charge_set = build(
      encounter: enc,
      procedures: [ proc ],
      conditions: [ c1 ],
      coverage: Factory.coverage(id: "cov-g1", payor: patient_payor)
    )

    assert_equal 1, charge_set.lines.length
    assert_nil charge_set.coverage.payer_identifier
    assert_diagnoses_exact(charge_set, [ [ 1, "F41.1" ] ])
    assert_problems_exact(charge_set, [ [ :coverage_payer_not_organization, "Coverage/cov-g1" ] ])
    refute_includes charge_set.inspect, trap_id
  end

  def test_g2_rendering_npi_system_on_practitioner_performer
    enc = Factory.encounter
    c1 = Factory.condition(id: "c1", icd10: "F41.1")
    dual_ids = [
      { "system" => Factory::STAFF_ID_SYSTEM, "value" => "STAFF-42" },
      { "system" => Factory::NPI, "value" => Factory::RENDERING_NPI }
    ]
    with_npi = Factory.procedure(
      id: "p-npi", encounter_id: enc.fetch("id"), code: "90834",
      performers: [ Factory.practitioner_performer_with_identifiers(identifiers: dual_ids) ],
      reason_condition_ids: [ "c1" ]
    )
    npi_set = build(encounter: enc, procedures: [ with_npi ], conditions: [ c1 ])
    assert_equal Factory::RENDERING_NPI, npi_set.rendering_provider_npi
    assert_empty npi_set.problems

    staff_only = Factory.procedure(
      id: "p-staff", encounter_id: enc.fetch("id"), code: "90834",
      performers: [
        Factory.practitioner_performer_with_identifiers(
          identifiers: [ { "system" => Factory::STAFF_ID_SYSTEM, "value" => "STAFF-42" } ]
        )
      ],
      reason_condition_ids: [ "c1" ]
    )
    staff_set = build(encounter: enc, procedures: [ staff_only ], conditions: [ c1 ])
    assert_equal 1, staff_set.lines.length
    assert_nil staff_set.rendering_provider_npi
    assert_problems_exact(staff_set, [ [ :rendering_provider_missing, "Procedure/p-staff" ] ])
  end

  def test_g3_duplicate_encounter_diagnosis_rank_is_ambiguous
    enc = Factory.encounter(
      id: "enc-g3",
      diagnosis: [
        Factory.encounter_diagnosis_ref("c-a", rank: 1),
        Factory.encounter_diagnosis_ref("c-b", rank: 1)
      ]
    )
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90834")
    charge_set = build(
      encounter: enc,
      procedures: [ proc ],
      conditions: [
        Factory.condition(id: "c-a", icd10: "F41.1"),
        Factory.condition(id: "c-b", icd10: "F32.9")
      ]
    )

    assert_empty charge_set.lines
    assert_empty charge_set.diagnoses
    assert_problems_exact(charge_set, [
      [ :diagnosis_rank_ambiguous, "Encounter/enc-g3" ],
      [ :no_diagnosis, "Procedure/p1" ]
    ])
  end

  def test_g4_procedure_with_conflicting_cpt_codes_is_ambiguous
    enc = Factory.encounter
    c1 = Factory.condition(id: "c1", icd10: "F41.1")
    ambiguous = Factory.procedure(
      id: "p-ambig", encounter_id: enc.fetch("id"), code: "90834",
      code_codings: [
        { "system" => Factory::CPT, "code" => "90834" },
        { "system" => Factory::CPT, "code" => "90837" }
      ],
      reason_condition_ids: [ "c1" ]
    )
    ambiguous_set = build(encounter: enc, procedures: [ ambiguous ], conditions: [ c1 ])
    assert_empty ambiguous_set.lines
    assert_empty ambiguous_set.diagnoses
    assert_problems_exact(ambiguous_set, [ [ :procedure_code_ambiguous, "Procedure/p-ambig" ] ])

    repeated = Factory.procedure(
      id: "p-dup-code", encounter_id: enc.fetch("id"), code: "90834",
      code_codings: [
        { "system" => Factory::CPT, "code" => "90834" },
        { "system" => Factory::CPT, "code" => "90834" }
      ],
      reason_condition_ids: [ "c1" ]
    )
    repeated_set = build(encounter: enc, procedures: [ repeated ], conditions: [ c1 ])
    assert_equal 1, repeated_set.lines.length
    assert_empty repeated_set.problems
  end

  def test_g5_audio_only_modifier_must_be_two_uppercase_alphanumeric_chars
    enc = Factory.encounter(class_code: "VR", at_home: true, audio_only_type: true)
    c1 = Factory.condition(id: "c1", icd10: "F41.1")
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90837",
                             reason_condition_ids: [ "c1" ])

    valid = build(
      encounter: enc,
      procedures: [ proc ],
      conditions: [ c1 ],
      coverage: Factory.coverage(id: "cov-valid", audio_only_modifier: "FQ")
    )
    assert_equal 1, valid.lines.length
    assert_equal [ "FQ" ], valid.lines.first.modifiers
    assert_empty valid.problems

    [ "fq", "Jane prefers phone", "F" ].each do |bad_modifier|
      bad = build(
        encounter: enc,
        procedures: [ Factory.procedure(id: "p-bad-#{bad_modifier.hash.abs}", encounter_id: enc.fetch("id"),
                                        code: "90837", reason_condition_ids: [ "c1" ]) ],
        conditions: [ c1 ],
        coverage: Factory.coverage(id: "cov-bad", audio_only_modifier: bad_modifier)
      )
      assert_empty bad.lines, bad_modifier
      assert_problems_exact(bad, [ [ :audio_only_modifier_invalid, "Coverage/cov-bad" ] ])
    end
  end

  def test_g6_serviced_date_rejects_hour_24_and_malformed_datetime_without_period_fallback
    enc = Factory.encounter
    c1 = Factory.condition(id: "c1", icd10: "F41.1")

    hour24 = Factory.procedure(
      id: "p-hour24", encounter_id: enc.fetch("id"), code: "90834",
      performed_at: nil, performed_date_time: "2026-08-15T24:00:00Z",
      reason_condition_ids: [ "c1" ]
    )
    hour24_set = build(encounter: enc, procedures: [ hour24 ], conditions: [ c1 ])
    assert_empty hour24_set.lines
    assert_problems_exact(hour24_set, [ [ :serviced_date_missing, "Procedure/p-hour24" ] ])

    no_fallback = Factory.procedure(
      id: "p-no-fallback", encounter_id: enc.fetch("id"), code: "90834",
      performed_at: "2026-08-15T14:00:00-07:00",
      performed_end: "2026-08-15T15:00:00-07:00",
      performed_date_time: "2026-08-15Tnonsense",
      reason_condition_ids: [ "c1" ]
    )
    no_fallback_set = build(encounter: enc, procedures: [ no_fallback ], conditions: [ c1 ])
    assert_empty no_fallback_set.lines
    assert_problems_exact(no_fallback_set, [ [ :serviced_date_missing, "Procedure/p-no-fallback" ] ])
  end

  def test_g7_home_location_requires_absent_active_or_completed_status
    enc = Factory.encounter(
      class_code: "VR",
      locations: [
        {
          "status" => "planned",
          "location" => { "reference" => "Location/loc-planned-home" },
          "physicalType" => {
            "coding" => [ { "system" => Factory::LOCATION_PHYSICAL, "code" => "ho" } ]
          }
        },
        {
          "status" => "completed",
          "location" => { "reference" => "Location/loc-room" },
          "physicalType" => {
            "coding" => [ { "system" => Factory::LOCATION_PHYSICAL, "code" => "ro" } ]
          }
        }
      ]
    )
    c1 = Factory.condition(id: "c1", icd10: "F41.1")
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90837",
                             reason_condition_ids: [ "c1" ])
    charge_set = build(encounter: enc, procedures: [ proc ], conditions: [ c1 ])

    assert_equal 1, charge_set.lines.length
    line = charge_set.lines.first
    assert_equal "02", line.place_of_service
    assert_equal [ "95" ], line.modifiers
    assert_empty charge_set.problems
  end

  def test_g8_claim_diagnoses_only_include_fallback_principal_not_all_encounter_dx
    icd_codes = %w[F41.1 F32.9 F33.0 F34.1 F40.0 F41.0 F42.0 F43.10 F43.20 F44.0 F45.0 F48.1 F50.0]
    diagnosis_refs = icd_codes.each_with_index.map do |_code, index|
      Factory.encounter_diagnosis_ref("c-rank-#{index + 1}", rank: index + 1)
    end
    enc = Factory.encounter(id: "enc-g8", diagnosis: diagnosis_refs)
    conditions = icd_codes.each_with_index.map do |code, index|
      Factory.condition(id: "c-rank-#{index + 1}", icd10: code)
    end
    proc = Factory.procedure(id: "p-fallback", encounter_id: enc.fetch("id"), code: "90834")
    charge_set = build(encounter: enc, procedures: [ proc ], conditions: conditions)

    assert_equal 1, charge_set.lines.length
    assert_equal 1, charge_set.diagnoses.length
    assert_diagnoses_exact(charge_set, [ [ 1, "F41.1" ] ])
    assert_equal [ 1 ], charge_set.lines.first.diagnosis_sequences
    assert_empty charge_set.problems
  end

  def test_g9_encounter_class_with_multiple_act_code_codings_is_unknown_modality
    enc = Factory.encounter(
      class_codings: [
        { "system" => Factory::ACT_CODE, "code" => "AMB" },
        { "system" => Factory::ACT_CODE, "code" => "VR" }
      ]
    )
    proc = Factory.procedure(
      id: "p1", encounter_id: enc.fetch("id"), code: "90834",
      reason_condition_ids: [ "c1" ]
    )
    charge_set = build(
      encounter: enc,
      procedures: [ proc ],
      conditions: [ Factory.condition(id: "c1", icd10: "F41.1") ],
      price_list: refute_price_list_called
    )

    assert_empty charge_set.lines
    assert_empty charge_set.diagnoses
    assert_problems_exact(charge_set, [ [ :encounter_modality_unknown, nil ] ])
  end

  def test_g10_every_verification_status_coding_must_be_billable_in_cvs
    enc = Factory.encounter
    base_proc = lambda do |cond_id|
      Factory.procedure(
        id: "p-#{cond_id}", encounter_id: enc.fetch("id"), code: "90834",
        reason_condition_ids: [ cond_id ]
      )
    end
    cvs = Factory::CONDITION_VERIFICATION

    mixed_local = Factory.condition(
      id: "c-mixed-local",
      icd10: "F41.1",
      verification_codings: [
        { "system" => "http://example.org/local-ver", "code" => "refuted" },
        { "system" => cvs, "code" => "confirmed" }
      ]
    )
    mixed_set = build(
      encounter: enc,
      procedures: [ base_proc.call("c-mixed-local") ],
      conditions: [ mixed_local ]
    )
    assert_empty mixed_set.lines
    assert_empty mixed_set.diagnoses
    assert_problems_exact(mixed_set, [
      [ :diagnosis_not_billable, "Condition/c-mixed-local" ],
      [ :no_diagnosis, "Procedure/p-c-mixed-local" ]
    ])

    confirmed_then_refuted = Factory.condition(
      id: "c-c-then-r",
      icd10: "F41.1",
      verification_codings: [
        { "system" => cvs, "code" => "confirmed" },
        { "system" => cvs, "code" => "refuted" }
      ]
    )
    ctr_set = build(
      encounter: enc,
      procedures: [ base_proc.call("c-c-then-r") ],
      conditions: [ confirmed_then_refuted ]
    )
    assert_empty ctr_set.lines
    assert_problems_exact(ctr_set, [
      [ :diagnosis_not_billable, "Condition/c-c-then-r" ],
      [ :no_diagnosis, "Procedure/p-c-c-then-r" ]
    ])

    refuted_then_confirmed = Factory.condition(
      id: "c-r-then-c",
      icd10: "F41.1",
      verification_codings: [
        { "system" => cvs, "code" => "refuted" },
        { "system" => cvs, "code" => "confirmed" }
      ]
    )
    rtc_set = build(
      encounter: enc,
      procedures: [ base_proc.call("c-r-then-c") ],
      conditions: [ refuted_then_confirmed ]
    )
    assert_empty rtc_set.lines
    assert_problems_exact(rtc_set, [
      [ :diagnosis_not_billable, "Condition/c-r-then-c" ],
      [ :no_diagnosis, "Procedure/p-c-r-then-c" ]
    ])
  end

  # -- ADR 0003 ---------------------------------------------------------------

  def test_charge_set_inspect_emits_no_free_text_phi_from_fixtures
    enc = Factory.encounter
    cond = Factory.condition(id: "c1", icd10: "F41.1", note: Factory::PHI_TRAP_NOTE)
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90834",
                             note: Factory::PHI_TRAP_NOTE, reason_condition_ids: [ "c1" ])
    charge_set = build(encounter: enc, procedures: [ proc ], conditions: [ cond ])
    rendered = charge_set.inspect

    refute_includes rendered, Factory::PHI_TRAP_NOTE
    refute_match(/SYNTH-SUB-GIVEN/, rendered)
    refute_match(/SYNTH-SUB-FAMILY/, rendered)
  end
end
