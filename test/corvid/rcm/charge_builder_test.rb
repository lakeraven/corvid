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
    proc = Factory.procedure(id: "p1", encounter_id: enc.fetch("id"), code: "90834",
                             npi: nil, reason_condition_ids: [ "c1" ])
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

    assert_equal [ "F41.1", "F32.9", "F33.0" ], charge_set.diagnoses.map(&:code)
    assert_equal [ 1, 2, 3 ], charge_set.diagnoses.map(&:sequence)
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
    assert_equal [ "F41.1", "F32.9" ], sorted.diagnoses.map(&:code)
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
