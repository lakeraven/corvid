# frozen_string_literal: true

require "minitest/autorun"
require "corvid/rcm"
require_relative "claim_factory"

# One test per v1 scrub rule. The baseline claim from the factory is clean, so
# each test breaks exactly one thing and asserts that exactly that rule fires,
# at the right severity, with a message a biller could act on.
class Corvid::Rcm::ScrubberTest < Minitest::Test
  Factory = Corvid::Rcm::ClaimFactory
  TODAY = Corvid::Rcm::ClaimFactory::TODAY

  def setup
    @scrubber = Corvid::Rcm::Scrubber.new
  end

  def scrub(claim, as_of: TODAY, history: Factory.history, **options)
    @scrubber.scrub(claim, as_of: as_of, history: history, **options)
  end

  def findings_for(result, rule_id)
    result.findings.select { |finding| finding.rule_id == rule_id }
  end

  def assert_only_rule(rule_id, result)
    assert_equal [ rule_id ], result.findings.map(&:rule_id).uniq,
                 "expected only #{rule_id}, got: #{result.findings.map(&:to_s).join(' | ')}"
  end

  # -- the clean baseline ----------------------------------------------------

  def test_a_clean_claim_produces_no_findings_and_is_submittable
    result = scrub(Factory.claim)

    assert result.clean?, "expected a clean scrub, got: #{result.findings.map(&:to_s).join(' | ')}"
    assert result.submittable?
    assert_equal Corvid::Rcm::ScrubRuleset.default.version, result.ruleset_version
  end

  # -- structural completeness -----------------------------------------------

  def test_missing_rendering_provider_npi_blocks
    result = scrub(Factory.claim(rendering_provider_npi: nil))

    assert_only_rule(:rendering_provider_npi_present, result)
    refute result.submittable?
    finding = result.findings.first
    assert_equal :block, finding.severity
    assert_match(/rendering provider NPI is missing/, finding.message)
    assert_match(/10-digit NPI/, finding.remedy)
  end

  def test_npi_with_a_bad_check_digit_blocks
    result = scrub(Factory.claim(rendering_provider_npi: "1299999998"))

    assert_only_rule(:rendering_provider_npi_present, result)
    assert_match(/check digit does not validate/, result.findings.first.message)
  end

  def test_npi_of_the_wrong_length_blocks
    result = scrub(Factory.claim(billing_provider_npi: "12345"))

    assert_only_rule(:billing_provider_npi_present, result)
    assert_match(/not 10 digits/, result.findings.first.message)
  end

  def test_missing_tax_id_blocks
    result = scrub(Factory.claim(billing_provider_tax_id: nil))

    assert_only_rule(:billing_provider_tax_id_present, result)
  end

  def test_missing_taxonomy_blocks
    result = scrub(Factory.claim(rendering_provider_taxonomy: nil))

    assert_only_rule(:rendering_provider_taxonomy_present, result)
    assert_match(/taxonomy/, result.findings.first.message)
  end

  def test_missing_payer_identifier_blocks
    result = scrub(Factory.claim(coverage: Factory.coverage(payer_identifier: "")))

    assert_includes result.blocked_by, :payer_identifier_present
    assert_match(/no payer identifier/, findings_for(result, :payer_identifier_present).first.message)
  end

  def test_terminated_coverage_blocks
    coverage = Factory.coverage(status: "cancelled")
    result = scrub(Factory.claim(coverage: coverage))

    assert_only_rule(:coverage_active_on_service_date, result)
    assert_match(/not active/, result.findings.first.message)
  end

  def test_coverage_that_ended_before_the_date_of_service_blocks
    coverage = Factory.coverage(period_end: Date.new(2026, 6, 30))
    result = scrub(Factory.claim(coverage: coverage))

    assert_only_rule(:coverage_active_on_service_date, result)
    assert_match(/terminated 2026-06-30/, result.findings.first.message)
    assert_equal 1, result.findings.first.line_sequence
  end

  def test_demographics_that_disagree_with_the_coverage_subscriber_block
    result = scrub(Factory.claim(patient_birth_date: Date.new(1988, 4, 3), patient_gender: "M"))

    assert_only_rule(:patient_demographics_match_subscriber, result)
    assert_match(/date of birth/, result.findings.first.message)
    assert_match(/gender/, result.findings.first.message)
  end

  def test_demographics_are_not_compared_when_the_patient_is_not_the_subscriber
    coverage = Factory.coverage(relationship: "child", subscriber_birth_date: Date.new(1960, 1, 1))
    result = scrub(Factory.claim(coverage: coverage))

    assert result.clean?
  end

  def test_a_line_pointing_at_a_diagnosis_that_is_not_on_the_claim_blocks
    result = scrub(Factory.claim_with_line(diagnosis_sequences: [ 4 ]))

    assert_only_rule(:diagnosis_pointers_resolve, result)
    assert_match(/points at diagnosis 4/, result.findings.first.message)
  end

  def test_a_line_pointing_at_no_diagnosis_at_all_blocks
    result = scrub(Factory.claim_with_line(diagnosis_sequences: []))

    assert_only_rule(:diagnosis_pointers_resolve, result)
    assert_match(/points at no diagnosis/, result.findings.first.message)
  end

  # -- place of service / telehealth -----------------------------------------
  #
  # These block loudly on purpose: a POS/modifier mismatch does not cost one
  # claim, it costs the whole telehealth book until somebody notices.

  def test_in_person_encounter_billed_at_a_telehealth_place_of_service_blocks
    result = scrub(Factory.claim_with_line(encounter_modality: :in_person, place_of_service: "02"))

    assert_only_rule(:place_of_service_matches_encounter_modality, result)
    assert_equal :block, result.findings.first.severity
    assert_match(/expected "11"/, result.findings.first.message)
  end

  def test_in_person_encounter_carrying_a_telehealth_modifier_blocks
    result = scrub(Factory.claim_with_line(modifiers: [ "95" ]))

    assert_only_rule(:place_of_service_matches_encounter_modality, result)
    assert_match(/modifier "95" which does not belong/, result.findings.first.message)
  end

  def test_telehealth_to_the_patient_home_requires_place_of_service_10_with_modifier_95
    clean = scrub(Factory.claim_with_line(
      encounter_modality: :telehealth_patient_home, place_of_service: "10", modifiers: [ "95" ]
    ))
    assert clean.clean?

    wrong_pos = scrub(Factory.claim_with_line(
      encounter_modality: :telehealth_patient_home, place_of_service: "02", modifiers: [ "95" ]
    ))
    assert_only_rule(:place_of_service_matches_encounter_modality, wrong_pos)
    assert_match(/expected "10"/, wrong_pos.findings.first.message)

    missing_modifier = scrub(Factory.claim_with_line(
      encounter_modality: :telehealth_patient_home, place_of_service: "10", modifiers: []
    ))
    assert_match(/missing modifier "95"/, missing_modifier.findings.first.message)
  end

  def test_other_telehealth_requires_place_of_service_02_with_modifier_95
    clean = scrub(Factory.claim_with_line(
      encounter_modality: :telehealth_other, place_of_service: "02", modifiers: [ "95" ]
    ))
    assert clean.clean?

    result = scrub(Factory.claim_with_line(
      encounter_modality: :telehealth_other, place_of_service: "11", modifiers: [ "95" ]
    ))
    assert_only_rule(:place_of_service_matches_encounter_modality, result)
    assert_match(/expected "02"/, result.findings.first.message)
  end

  def test_audio_only_uses_the_payer_specific_modifier_from_the_coverage
    clean = scrub(Factory.claim_with_line(
      encounter_modality: :audio_only, place_of_service: "10", modifiers: [ "93" ]
    ))
    assert clean.clean?

    video_modifier = scrub(Factory.claim_with_line(
      encounter_modality: :audio_only, place_of_service: "10", modifiers: [ "95" ]
    ))
    assert_only_rule(:place_of_service_matches_encounter_modality, video_modifier)
    assert_match(/missing modifier "93"/, video_modifier.findings.first.message)
  end

  def test_audio_only_honours_a_payer_that_requires_a_different_modifier
    coverage = Factory.coverage(audio_only_modifier: "FQ")
    claim = Factory.claim(
      coverage: coverage,
      items: [ Factory.line(encounter_modality: :audio_only, place_of_service: "02", modifiers: [ "FQ" ]) ]
    )

    assert scrub(claim).clean?
  end

  def test_audio_only_without_a_configured_payer_policy_warns_but_does_not_block
    coverage = Factory.coverage(audio_only_modifier: nil)
    claim = Factory.claim(
      coverage: coverage,
      items: [ Factory.line(encounter_modality: :audio_only, place_of_service: "10", modifiers: [ "93" ]) ]
    )
    result = scrub(claim)

    assert_only_rule(:audio_only_modifier_policy_confirmed, result)
    assert_equal :warn, result.findings.first.severity
    assert result.submittable?, "a policy warning must not stop the claim"
    assert_match(/default modifier 93/, result.findings.first.message)
  end

  def test_a_line_that_does_not_record_how_the_encounter_happened_blocks
    result = scrub(Factory.claim_with_line(encounter_modality: nil))

    assert_only_rule(:place_of_service_matches_encounter_modality, result)
    assert_match(/does not record how the encounter happened/, result.findings.first.message)
  end

  # Regression: an unrecognised modality used to fall straight through the
  # check, so a typo on a telehealth encounter shipped POS 11 with modifier 95
  # — the whole-book denial this rule exists to prevent. Unknown fails as
  # closed as missing.
  def test_a_line_recording_an_unrecognised_modality_blocks
    result = scrub(Factory.claim_with_line(encounter_modality: :telehalth_patient_home,
                                            place_of_service: "10", modifiers: [ "95" ]))

    assert_only_rule(:place_of_service_matches_encounter_modality, result)
    assert_equal :block, result.findings.first.severity
    refute result.submittable?
    assert_match(/does not recognise/, result.findings.first.message)
    assert_match(/telehalth_patient_home/, result.findings.first.message)
  end

  def test_an_unrecognised_modality_cannot_slip_a_telehealth_modifier_past_an_office_place_of_service
    result = scrub(Factory.claim_with_line(encounter_modality: :video,
                                            place_of_service: "11", modifiers: [ "95" ]))

    refute result.submittable?, "an unverifiable modality must not transmit"
  end

  # -- time-supported coding --------------------------------------------------

  def test_the_60_minute_code_blocks_below_53_documented_minutes
    result = scrub(Factory.claim_with_line(documented_minutes: 45))

    assert_only_rule(:psychotherapy_60_minute_time_support, result)
    assert_equal :block, result.findings.first.severity
    assert_match(/45 minutes/, result.findings.first.message)
    assert_match(/at least 53 minutes/, result.findings.first.message)
  end

  def test_the_60_minute_code_blocks_when_no_time_is_documented_at_all
    result = scrub(Factory.claim_with_line(documented_minutes: nil))

    assert_only_rule(:psychotherapy_60_minute_time_support, result)
    assert_match(/no documented time/, result.findings.first.message)
  end

  def test_the_60_minute_code_passes_at_exactly_53_documented_minutes
    assert scrub(Factory.claim_with_line(documented_minutes: 53)).clean?
  end

  def test_the_45_minute_code_requires_38_to_52_documented_minutes
    assert scrub(Factory.claim_with_line(procedure_code: "90834", documented_minutes: 38)).clean?
    assert scrub(Factory.claim_with_line(procedure_code: "90834", documented_minutes: 52)).clean?

    too_short = scrub(Factory.claim_with_line(procedure_code: "90834", documented_minutes: 30))
    assert_only_rule(:psychotherapy_45_minute_time_support, too_short)
    assert_match(/requires 38-52 minutes/, too_short.findings.first.message)

    too_long = scrub(Factory.claim_with_line(procedure_code: "90834", documented_minutes: 60))
    assert_only_rule(:psychotherapy_45_minute_time_support, too_long)
    assert_match(/bill 90837/, too_long.findings.first.remedy)
  end

  def test_a_repeat_diagnostic_evaluation_within_12_months_warns_without_blocking
    history = Factory.history(
      Factory.prior_service(procedure_code: "90791", serviced_date: Date.new(2026, 2, 10))
    )
    result = scrub(Factory.claim_with_line(procedure_code: "90791", documented_minutes: 60), history: history)

    assert_only_rule(:diagnostic_evaluation_repeat_within_window, result)
    assert_equal :warn, result.findings.first.severity
    assert result.submittable?
    assert_match(/2026-02-10/, result.findings.first.message)
  end

  def test_a_diagnostic_evaluation_outside_the_window_does_not_warn
    history = Factory.history(
      Factory.prior_service(procedure_code: "90791", serviced_date: Date.new(2025, 1, 10))
    )
    result = scrub(Factory.claim_with_line(procedure_code: "90791"), history: history)

    assert result.clean?
  end

  def test_a_repeat_by_a_different_rendering_provider_does_not_warn
    history = Factory.history(
      Factory.prior_service(procedure_code: "90791", rendering_provider_npi: "1555555550",
                            serviced_date: Date.new(2026, 2, 10))
    )
    result = scrub(Factory.claim_with_line(procedure_code: "90791"), history: history)

    assert result.clean?
  end

  # -- diagnosis coding -------------------------------------------------------

  def test_a_malformed_diagnosis_code_blocks
    result = scrub(Factory.claim(diagnoses: [ Factory.diagnosis("F4321") ]))

    assert_only_rule(:diagnosis_code_well_formed, result)
    assert_equal :block, result.findings.first.severity
    refute result.submittable?
    assert_match(/not a well-formed ICD-10-CM code/, result.findings.first.message)
  end

  def test_a_diagnosis_with_no_code_at_all_blocks
    result = scrub(Factory.claim(diagnoses: [ Factory.diagnosis("") ]))

    assert_includes result.blocked_by, :diagnosis_code_well_formed
    assert_match(/carries no code at all/, findings_for(result, :diagnosis_code_well_formed).first.message)
  end

  def test_a_three_character_category_rubric_warns_without_blocking
    result = scrub(Factory.claim(diagnoses: [ Factory.diagnosis("F32") ]))

    assert_only_rule(:behavioral_health_diagnosis_likely_nonbillable, result)
    assert_equal :warn, result.findings.first.severity
    assert_match(/three-character category rubric/, result.findings.first.message)
  end

  def test_a_subcategory_header_warns_without_blocking
    result = scrub(Factory.claim(diagnoses: [ Factory.diagnosis("F43.2") ]))

    assert_only_rule(:behavioral_health_diagnosis_likely_nonbillable, result)
    assert_equal :warn, result.findings.first.severity
    assert_match(/subcategory header/, result.findings.first.message)
  end

  # The point of the severity split: a hand-maintained list is allowed to be
  # wrong about a code, but it is never allowed to stop a claim over it.
  def test_no_diagnosis_code_can_be_blocked_by_the_hand_maintained_list
    result = scrub(Factory.claim(diagnoses: [ Factory.diagnosis("F43.2") ]))

    assert result.submittable?, "a best-effort list must never block a claim"
  end

  def test_a_billable_f_series_diagnosis_passes
    assert scrub(Factory.claim(diagnoses: [ Factory.diagnosis("F43.23") ])).clean?
  end

  # Regression: these are billable ICD-10-CM leaf codes with no children. They
  # were on the non-billable list, so a claim carrying one was blocked and
  # never transmitted — the clinic denying its own legitimate claims.
  def test_billable_four_character_f_codes_are_not_flagged
    %w[F33.8 F41.8 F84.8 F90.8].each do |code|
      result = scrub(Factory.claim(diagnoses: [ Factory.diagnosis(code) ]))

      assert result.clean?, "#{code} is billable and should raise no finding, got: #{result.findings.map(&:to_s).join(' | ')}"
    end
  end

  # Regression: "three characters" does not mean "header". These rubrics have
  # no subcategories and are billable exactly as written.
  def test_billable_three_character_f_rubrics_are_not_flagged
    %w[F09 F21 F23 F29 F70 F82 F99].each do |code|
      result = scrub(Factory.claim(diagnoses: [ Factory.diagnosis(code) ]))

      assert result.clean?, "#{code} is a billable rubric and should raise no finding, got: #{result.findings.map(&:to_s).join(' | ')}"
    end
  end

  # -- filing window and duplicates -------------------------------------------

  def test_half_the_filing_window_elapsed_warns_without_blocking
    coverage = Factory.coverage(timely_filing_days: 90)
    result = scrub(Factory.claim(coverage: coverage), as_of: Date.new(2026, 10, 15))

    assert_only_rule(:timely_filing_window_half_elapsed, result)
    assert_equal :warn, result.findings.first.severity
    assert result.submittable?
    assert_match(/90-day filing window/, result.findings.first.message)
    assert_match(/days remain/, result.findings.first.message)
  end

  def test_an_expired_filing_window_blocks_and_does_not_also_warn
    coverage = Factory.coverage(timely_filing_days: 90)
    result = scrub(Factory.claim(coverage: coverage), as_of: Date.new(2027, 1, 15))

    assert_only_rule(:timely_filing_window_expired, result)
    refute result.submittable?
    assert_match(/closed on 2026-11-13/, result.findings.first.message)
  end

  def test_an_unconfigured_filing_window_produces_no_filing_findings
    coverage = Factory.coverage(timely_filing_days: nil)
    result = scrub(Factory.claim(coverage: coverage), as_of: Date.new(2028, 1, 1))

    assert_empty findings_for(result, :timely_filing_window_expired)
    assert_empty findings_for(result, :timely_filing_window_half_elapsed)
  end

  def test_a_duplicate_patient_date_and_procedure_blocks
    history = Factory.history(Factory.prior_service(claim_identifier: "CLM-1900"))
    result = scrub(Factory.claim, history: history)

    assert_only_rule(:duplicate_service_already_submitted, result)
    assert_match(/already submitted for this patient on CLM-1900/, result.findings.first.message)
  end

  # A front-door rejection was never adjudicated, so resubmitting the fixed
  # claim cannot earn a CO-18 and must not be blocked as its own duplicate.
  def test_a_claim_resubmitted_after_a_front_door_rejection_is_not_its_own_duplicate
    history = Factory.history(Factory.prior_service(claim_identifier: "CLM-2001", rejected: true))

    assert scrub(Factory.claim, history: history).clean?
  end

  # Regression: history matching the claim's own identifier used to be
  # excluded wholesale, so re-sending an already-accepted claim under the same
  # identifier passed the duplicate check and came back CO-18.
  def test_resending_an_already_submitted_claim_under_the_same_identifier_blocks
    history = Factory.history(Factory.prior_service(claim_identifier: "CLM-2001"))
    result = scrub(Factory.claim, history: history)

    assert_only_rule(:duplicate_service_already_submitted, result)
    refute result.submittable?
  end

  def test_a_rejected_prior_on_another_claim_is_not_a_duplicate_either
    history = Factory.history(Factory.prior_service(claim_identifier: "CLM-1900", rejected: true))

    assert scrub(Factory.claim, history: history).clean?
  end

  def test_a_different_date_of_service_is_not_a_duplicate
    history = Factory.history(Factory.prior_service(serviced_date: Date.new(2026, 8, 8)))

    assert scrub(Factory.claim, history: history).clean?
  end

  def test_an_empty_history_means_no_duplicate_findings
    assert_empty findings_for(scrub(Factory.claim), :duplicate_service_already_submitted)
  end

  # Panel round 1: nil history is UNKNOWN, not "none" (the same nil/[] rule
  # main applies to adapter reads). Without it nobody can say the claim was
  # not already sent, so the duplicate rule blocks rather than passing.
  def test_no_history_at_all_blocks_the_duplicate_rule
    result = scrub(Factory.claim, history: nil)

    assert_only_rule(:duplicate_service_already_submitted, result)
    refute result.submittable?
    assert_match(/no claim history/i, result.findings.first.message)
  end

  # Regression: duplicate detection used to consult history only, so the
  # easiest duplicate of all — the same line twice on one claim — sailed
  # through and came back CO-18.
  def test_the_same_line_twice_on_one_claim_blocks_without_any_history
    claim = Factory.claim(items: [ Factory.line(sequence: 1), Factory.line(sequence: 2) ])
    result = scrub(claim)

    assert_only_rule(:duplicate_service_already_submitted, result)
    refute result.submittable?
    assert_equal 2, result.findings.first.line_sequence
    assert_match(/repeats line 1 on this same claim/, result.findings.first.message)
  end

  def test_two_same_day_lines_on_one_claim_pass_when_a_modifier_tells_them_apart
    claim = Factory.claim(items: [
      Factory.line(sequence: 1),
      Factory.line(sequence: 2, modifiers: [ "59" ])
    ])

    assert scrub(claim).clean?
  end

  def test_two_same_day_lines_carrying_the_same_modifier_are_still_duplicates
    claim = Factory.claim(items: [
      Factory.line(sequence: 1, modifiers: [ "59" ]),
      Factory.line(sequence: 2, modifiers: [ "59" ])
    ])

    assert_only_rule(:duplicate_service_already_submitted, scrub(claim))
  end

  def test_different_procedure_codes_on_the_same_day_are_not_duplicates
    claim = Factory.claim(items: [
      Factory.line(sequence: 1),
      Factory.line(sequence: 2, procedure_code: "90834", documented_minutes: 45)
    ])

    assert scrub(claim).clean?
  end

  # Regression: the remedy promises a distinct-service modifier as the way to
  # bill a genuinely separate second session. It has to actually work, or a
  # clinic that saw a patient twice in a day can never bill the second visit.
  def test_a_distinct_service_modifier_clears_a_history_duplicate
    history = Factory.history(Factory.prior_service(claim_identifier: "CLM-1900"))
    claim = Factory.claim_with_line(modifiers: [ "XE" ])

    assert scrub(claim, history: history).clean?
  end

  def test_a_history_duplicate_still_blocks_when_the_prior_carries_the_same_modifier
    history = Factory.history(Factory.prior_service(claim_identifier: "CLM-1900", modifiers: [ "XE" ]))
    result = scrub(Factory.claim_with_line(modifiers: [ "XE" ]), history: history)

    assert_only_rule(:duplicate_service_already_submitted, result)
  end

  # -- the engine itself ------------------------------------------------------

  def test_an_empty_claim_reports_every_structural_problem_rather_than_raising
    bare = Corvid::Rcm::Claim.new(identifier: "CLM-EMPTY", patient_identifier: "pt_0002")
    result = @scrubber.scrub(bare, as_of: TODAY, history: Factory.history)

    refute result.submittable?
    assert_includes result.blocked_by, :rendering_provider_npi_present
    assert_includes result.blocked_by, :billing_provider_npi_present
    assert_includes result.blocked_by, :payer_identifier_present
  end

  def test_findings_carry_the_ruleset_version_they_were_produced_by
    result = scrub(Factory.claim(rendering_provider_npi: nil))

    assert_equal result.ruleset_version, result.findings.first.ruleset_version
  end

  def test_rules_are_filtered_by_their_effective_window
    ruleset = Corvid::Rcm::ScrubRuleset.from_hash(
      "ruleset_version" => "test-1",
      "rules" => [
        { "id" => "retired", "category" => "structural_completeness", "severity" => "block",
          "check" => "npi_valid", "params" => { "field" => "rendering_provider_npi" },
          "message" => "retired rule", "effective_end" => "2025-12-31" },
        { "id" => "future", "category" => "structural_completeness", "severity" => "block",
          "check" => "npi_valid", "params" => { "field" => "rendering_provider_npi" },
          "message" => "future rule", "effective_start" => "2027-01-01" }
      ]
    )
    scrubber = Corvid::Rcm::Scrubber.new(ruleset: ruleset)
    claim = Factory.claim(rendering_provider_npi: nil)

    assert_empty scrubber.scrub(claim, as_of: Date.new(2026, 6, 1)).findings
    assert_equal [ :retired ], scrubber.scrub(claim, as_of: Date.new(2025, 6, 1)).findings.map(&:rule_id)
    assert_equal [ :future ], scrubber.scrub(claim, as_of: Date.new(2027, 6, 1)).findings.map(&:rule_id)
  end

  def test_a_rule_naming_a_check_that_does_not_exist_fails_loudly
    ruleset = Corvid::Rcm::ScrubRuleset.from_hash(
      "ruleset_version" => "test-2",
      "rules" => [ { "id" => "bogus", "check" => "no_such_check", "message" => "x" } ]
    )

    error = assert_raises(Corvid::Rcm::Scrubber::UnknownCheck) do
      Corvid::Rcm::Scrubber.new(ruleset: ruleset).scrub(Factory.claim, as_of: TODAY, history: Factory.history)
    end
    assert_match(/no_such_check/, error.message)
  end

  def test_every_shipped_rule_names_a_check_that_exists
    Corvid::Rcm::ScrubRuleset.default.rules.each do |rule|
      assert Corvid::Rcm::ScrubChecks.respond_to?(rule.check),
             "rule #{rule.id} names missing check #{rule.check}"
    end
  end

  def test_every_shipped_rule_carries_a_remedy
    Corvid::Rcm::ScrubRuleset.default.rules.each do |rule|
      refute_nil rule.remedy, "rule #{rule.id} has no remedy — a finding without a next action is noise"
    end
  end

  # -- review regressions: identifiers have to be well-formed as written ------

  def test_an_npi_with_non_digit_characters_blocks_even_when_its_digits_would_validate
    result = scrub(Factory.claim(rendering_provider_npi: "abc#{Factory::RENDERING_NPI}"))

    assert_only_rule(:rendering_provider_npi_present, result)
  end

  def test_a_tax_id_with_non_digit_characters_blocks
    result = scrub(Factory.claim(billing_provider_tax_id: "abc990000001"))

    assert_only_rule(:billing_provider_tax_id_present, result)
  end

  def test_a_hyphenated_ein_is_a_valid_tax_id
    assert scrub(Factory.claim(billing_provider_tax_id: "99-0000001")).clean?
  end

  # -- review regressions: a claim has to carry what the 837P needs ------------

  def test_a_claim_with_no_service_lines_blocks
    result = scrub(Factory.claim(items: []))

    assert_only_rule(:service_lines_present, result)
    refute result.submittable?
  end

  def test_a_service_line_with_no_date_of_service_blocks
    result = scrub(Factory.claim_with_line(serviced_date: nil))

    assert_includes result.blocked_by, :service_line_complete
    assert_match(/date of service/, findings_for(result, :service_line_complete).first.message)
  end

  def test_a_service_line_with_no_procedure_code_blocks
    result = scrub(Factory.claim_with_line(procedure_code: nil))

    assert_includes result.blocked_by, :service_line_complete
  end

  def test_a_service_line_with_no_billed_amount_blocks
    result = scrub(Factory.claim_with_line(billed_amount: nil))

    assert_only_rule(:service_line_complete, result)
    assert_match(/billed amount/, result.findings.first.message)
  end

  def test_a_service_line_with_a_zero_or_negative_billed_amount_blocks
    assert_only_rule(:service_line_complete, scrub(Factory.claim_with_line(billed_amount: 0)))
    assert_only_rule(:service_line_complete, scrub(Factory.claim_with_line(billed_amount: BigDecimal("-5"))))
  end

  def test_a_service_line_whose_source_amount_was_unparseable_blocks
    result = scrub(Factory.claim_with_line(billed_amount: nil, amount_error: "unparseable billed amount"))

    assert_only_rule(:service_line_complete, result)
    assert_match(/unparseable/, result.findings.first.message)
  end

  def test_a_service_line_with_fractional_cents_blocks
    assert_only_rule(:service_line_complete, scrub(Factory.claim_with_line(billed_amount: BigDecimal("200.005"))))
  end

  def test_missing_patient_demographics_block
    { patient_family_name: "family name", patient_given_name: "given name",
      patient_birth_date: "date of birth", patient_gender: "gender" }.each do |field, label|
      result = scrub(Factory.claim(field => nil))

      assert_only_rule(:patient_demographics_present, result)
      assert_match(/#{label}/, result.findings.first.message)
    end
  end

  # Absence never verifies: a self-coverage record with no subscriber birth
  # date cannot confirm that the claim's birth date matches the payer's.
  def test_a_subscriber_field_missing_from_self_coverage_cannot_be_matched_and_blocks
    result = scrub(Factory.claim(coverage: Factory.coverage(subscriber_birth_date: nil)))

    assert_only_rule(:patient_demographics_match_subscriber, result)
    assert_match(/date of birth/, result.findings.first.message)
  end

  # Findings are rendered and may be logged; per ADR 0003 they name the field
  # that disagrees, never the patient's name or birth date.
  def test_a_demographic_mismatch_names_the_field_but_not_the_values
    result = scrub(Factory.claim(patient_family_name: "EXAMPLEOTHER", patient_birth_date: Date.new(1988, 4, 3)))
    text = result.findings.map(&:to_s).join(" ")

    assert_only_rule(:patient_demographics_match_subscriber, result)
    assert_match(/family name/, text)
    refute_match(/EXAMPLEOTHER|EXAMPLEPATIENT|1988/, text)
  end

  # -- review regression: rule selection and the filing clock are different dates

  def test_rules_can_be_chosen_by_date_of_service_while_filing_is_judged_on_the_scrub_date
    coverage = Factory.coverage(timely_filing_days: 90)
    result = scrub(Factory.claim(coverage: coverage), as_of: Date.new(2027, 1, 15),
                   rules_as_of: Factory::SERVICE_DATE)

    assert_only_rule(:timely_filing_window_expired, result)
    assert_equal Factory::SERVICE_DATE, result.rules_as_of
    assert_equal Date.new(2027, 1, 15), result.evaluated_as_of
  end

  def test_rules_as_of_selects_the_rules_in_force_on_that_date
    ruleset = Corvid::Rcm::ScrubRuleset.from_hash(
      "ruleset_version" => "test-2",
      "rules" => [
        { "id" => "future", "category" => "structural_completeness", "severity" => "block",
          "check" => "npi_valid", "params" => { "field" => "rendering_provider_npi" },
          "message" => "future rule", "effective_start" => "2027-01-01" }
      ]
    )
    scrubber = Corvid::Rcm::Scrubber.new(ruleset: ruleset)
    claim = Factory.claim(rendering_provider_npi: nil)

    assert_empty scrubber.scrub(claim, as_of: Date.new(2027, 6, 1), rules_as_of: Factory::SERVICE_DATE).findings
    assert_equal [ :future ], scrubber.scrub(claim, as_of: Date.new(2027, 6, 1)).findings.map(&:rule_id)
  end

  # -- panel round 1 ------------------------------------------------------------

  # Regression: structural rules carried the ruleset's adoption date as their
  # effective start, so judging a 2025 date of service by "the rules in force
  # then" ran none of them and a claim with no NPI came back submittable.
  def test_rules_for_an_early_date_of_service_still_check_claim_completeness
    result = scrub(Factory.claim(rendering_provider_npi: nil), rules_as_of: Date.new(2025, 6, 1))

    assert_includes result.blocked_by, :rendering_provider_npi_present
    refute result.submittable?
  end

  def test_completeness_and_format_rules_are_in_force_on_any_date
    %i[rendering_provider_npi_present billing_provider_npi_present billing_provider_tax_id_present
       rendering_provider_taxonomy_present payer_identifier_present coverage_active_on_service_date
       patient_demographics_present service_lines_present service_line_complete
       patient_demographics_match_subscriber diagnosis_pointers_resolve diagnosis_code_well_formed
       timely_filing_window_expired duplicate_service_already_submitted].each do |rule_id|
      assert Corvid::Rcm::ScrubRuleset.default.rule(rule_id).effective_on?(Date.new(2000, 1, 1)),
             "#{rule_id} should not have an effective start"
    end
  end

  # Absence never verifies: with no filing window on file nobody can say the
  # claim is in time, so a human is told rather than silence passing for "yes".
  def test_an_unconfigured_filing_window_warns
    result = scrub(Factory.claim(coverage: Factory.coverage(timely_filing_days: nil)))

    assert_only_rule(:timely_filing_window_configured, result)
    assert_equal :warn, result.findings.first.severity
    assert result.submittable?
  end

  def test_an_infinite_billed_amount_blocks
    assert_only_rule(:service_line_complete, scrub(Factory.claim_with_line(billed_amount: Float::INFINITY)))
  end
end
