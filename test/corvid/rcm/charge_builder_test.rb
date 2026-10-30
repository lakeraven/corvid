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
    assert_equal reference, problem.reference
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
    assert_equal "cov-synth-1", cov.identifier
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
