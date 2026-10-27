# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "active_support/all"
require "active_support/testing/time_helpers"
require "corvid/adapters/mock_adapter"

class Corvid::Adapters::MockAdapterTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers

  def setup
    @saved_time_zone = Time.zone
    @adapter = Corvid::Adapters::MockAdapter.new
  end

  def teardown
    Time.zone = @saved_time_zone
  end

  # -- Vault: store_text + fetch_text round-trip ------------------------------

  def test_store_text_returns_prefixed_token
    token = @adapter.store_text(case_token: "ct_test", kind: :note, text: "TEST NOTE 001")
    assert_match(/\Ant_/, token)
  end

  def test_store_text_returns_unique_tokens
    a = @adapter.store_text(case_token: "ct_test", kind: :note, text: "A")
    b = @adapter.store_text(case_token: "ct_test", kind: :note, text: "B")
    refute_equal a, b
  end

  def test_fetch_text_round_trips
    token = @adapter.store_text(case_token: "ct_test", kind: :note, text: "TEST NOTE 001")
    assert_equal "TEST NOTE 001", @adapter.fetch_text(token)
  end

  def test_fetch_text_returns_nil_for_unknown_token
    assert_nil @adapter.fetch_text("nt_does_not_exist")
  end

  def test_store_text_uses_kind_specific_prefix
    note    = @adapter.store_text(case_token: "ct_x", kind: :note, text: "n")
    reason  = @adapter.store_text(case_token: "ct_x", kind: :reason, text: "r")
    rationale = @adapter.store_text(case_token: "ct_x", kind: :rationale, text: "ra")
    policy  = @adapter.store_text(case_token: "ct_x", kind: :policy, text: "p")

    assert_match(/\Ant_/, note)
    assert_match(/\Ars_/, reason)
    assert_match(/\Arn_/, rationale)
    assert_match(/\Apo_/, policy)
  end

  # -- Patient lookup returns PatientReference (no PHI by default) ------------

  def test_find_patient_returns_patient_reference
    @adapter.add_patient("pt_001", display_name: "TEST,PATIENT", dob: Date.new(1980, 1, 1), sex: "F", ssn_last4: "0000")
    result = @adapter.find_patient("pt_001")
    assert_instance_of Corvid::PatientReference, result
    assert_equal "pt_001", result.identifier
    assert_equal "TEST,PATIENT", result.display_name
  end

  def test_find_patient_returns_nil_for_unknown_token
    assert_nil @adapter.find_patient("pt_unknown")
  end

  # -- Practitioner lookup ----------------------------------------------------

  def test_find_practitioner_returns_practitioner_reference
    @adapter.add_practitioner("pr_001", display_name: "TEST,PROVIDER", npi: "0000000000", specialty: "TEST")
    result = @adapter.find_practitioner("pr_001")
    assert_instance_of Corvid::PractitionerReference, result
    assert_equal "pr_001", result.identifier
  end

  # -- Referral lookup --------------------------------------------------------

  def test_find_referral_returns_referral_reference
    @adapter.add_referral("rf_001", patient_identifier: "pt_001", status: "pending",
                          estimated_cost: 5000, medical_priority_level: 3,
                          authorization_number: "AUTH-001", emergent: false, urgent: false,
                          chs_approval_status: "P", service_requested: "TEST")
    result = @adapter.find_referral("rf_001")
    assert_instance_of Corvid::ReferralReference, result
    assert_equal "rf_001", result.identifier
    assert_equal "pt_001", result.patient_identifier
    assert_equal "AUTH-001", result.authorization_number
  end

  # -- Care team --------------------------------------------------------------

  def test_get_care_team_returns_array_of_references
    @adapter.add_care_team("pt_001", [
      { practitioner_identifier: "pr_001", role: "primary_care", name: "Primary Team", status: "active" }
    ])
    result = @adapter.get_care_team("pt_001")
    assert_equal 1, result.size
    assert_instance_of Corvid::CareTeamMemberReference, result.first
    assert_equal "pr_001", result.first.practitioner_identifier
  end

  def test_get_care_team_returns_empty_for_unknown_patient
    assert_equal [], @adapter.get_care_team("pt_unknown")
  end

  # -- Eligibility ------------------------------------------------------------

  def test_verify_eligibility_returns_eligible_for_seeded_resource_type
    @adapter.add_patient("pt_001", display_name: "TEST,PATIENT", dob: Date.new(1980, 1, 1), sex: "F", ssn_last4: "0000")
    @adapter.add_coverage("pt_001",
                          coverage_type: "medicaid",
                          payer_name: "MOCK MEDICAID PAYER",
                          plan_name: "Mock Medicaid",
                          eligible: true)
    result = @adapter.verify_eligibility("pt_001", "medicaid")
    assert result[:eligible]
    assert result[:payer_name]
  end

  # A coverage that never says it is eligible does not verify.
  def test_verify_eligibility_without_an_eligible_flag_is_not_eligible
    @adapter.add_coverage("pt_001", coverage_type: "medicaid", payer_name: "MOCK MEDICAID PAYER")

    result = @adapter.verify_eligibility("pt_001", "medicaid")

    refute_equal true, result&.dig(:eligible)
  end

  def test_verify_eligibility_with_a_non_boolean_eligible_stays_undetermined
    @adapter.add_coverage("pt_001", coverage_type: "medicaid", eligible: :unknown)

    assert_nil @adapter.verify_eligibility("pt_001", "medicaid")
  end

  def test_check_eligibility_detailed_without_an_eligible_flag_is_not_eligible
    @adapter.add_coverage("pt_001", coverage_type: "medicaid", payer_identifier: "MOCK_PAYER")

    refute_equal true, @adapter.check_eligibility_detailed("pt_001", "MOCK_PAYER")[:eligible]
  end

  # The requested type is matched against the coverage's own type, never a
  # payer or plan name that happens to spell the same word.
  def test_verify_eligibility_ignores_a_payer_identifier_that_names_another_type
    @adapter.add_coverage("pt_001",
                          coverage_type: "medicaid",
                          payer_identifier: "MEDICARE_A",
                          payer_name: "medicare_a",
                          plan_name: "medicare_a",
                          eligible: true)

    assert_nil @adapter.verify_eligibility("pt_001", "medicare_a")
    assert_equal true, @adapter.verify_eligibility("pt_001", "medicaid")[:eligible]
  end

  def test_check_eligibility_detailed_matches_the_payer_identifier_not_the_payer_name
    @adapter.add_coverage("pt_001",
                          coverage_type: "medicaid",
                          payer_identifier: "MOCK_PAYER",
                          payer_name: "OTHER_PAYER",
                          eligible: true)

    refute_equal true, @adapter.check_eligibility_detailed("pt_001", "OTHER_PAYER")[:eligible]
    assert_equal true, @adapter.check_eligibility_detailed("pt_001", "MOCK_PAYER")[:eligible]
  end

  # A type-less eligibility check is undetermined; it never answers from
  # whichever coverage happens to be first.
  def test_verify_eligibility_with_a_blank_resource_type_is_undetermined
    @adapter.add_patient("pt_001", display_name: "TEST,PATIENT", dob: Date.new(1980, 1, 1), sex: "F", ssn_last4: "0000")
    @adapter.add_coverage("pt_001",
                          coverage_type: "medicare_a",
                          payer_name: "MOCK MEDICARE PAYER",
                          eligible: true)
    @adapter.add_coverage("pt_001",
                          coverage_type: "medicaid",
                          payer_name: "MOCK MEDICAID PAYER",
                          eligible: true)

    [ nil, "", "   ", "\t \n", :"" ].each do |resource_type|
      assert_nil @adapter.verify_eligibility("pt_001", resource_type),
                 "resource_type #{resource_type.inspect} must not answer from arbitrary coverage"
    end

    assert_equal true, @adapter.verify_eligibility("pt_001", "medicaid")[:eligible]
    assert_equal true, @adapter.verify_eligibility("pt_001", "medicare_a")[:eligible]
  end

  # A detailed check that names no payer is undetermined; it never answers
  # from whichever coverage happens to be first.
  def test_check_eligibility_detailed_with_a_blank_payer_is_not_eligible
    @adapter.add_coverage("pt_001", coverage_type: "medicaid", payer_identifier: "PAYER_A", eligible: true)

    [ nil, "", "  " ].each do |payer|
      refute_equal true, @adapter.check_eligibility_detailed("pt_001", payer)[:eligible],
                   "payer #{payer.inspect} must not verify"
    end
  end

  # -- Claim lines --------------------------------------------------------------

  def test_list_claims_returns_seeded_lines_for_that_patient_only
    line = Corvid::ClaimLineReference.new(
      claim_identifier: "clm_test_001", patient_identifier: "pt_001", provider_identifier: "pr_001",
      procedure_code: "99213", procedure_display: "TEST VISIT", serviced_date: Date.new(2026, 1, 1),
      billed_amount: 100.0, currency: "USD", sequence: 1
    )
    @adapter.add_claim_line("pt_001", line)

    assert_equal [ "clm_test_001" ], @adapter.list_claims("pt_001").map(&:claim_identifier)
    assert_equal [], @adapter.list_claims("pt_002")
  end

  def test_add_claim_line_rejects_non_claim_line_references
    assert_raises(ArgumentError) { @adapter.add_claim_line("pt_001", { claim_identifier: "clm_test_001" }) }
  end

  def test_verify_eligibility_explicit_nil_coverage_dates_stay_nil
    @adapter.add_coverage("pt_test_001", resource_type: "medicaid", coverage_start: nil, coverage_end: nil, renewal_date: nil)
    result = @adapter.verify_eligibility("pt_test_001", "medicaid")
    assert_nil result[:coverage_start]
    assert_nil result[:coverage_end]
    assert_nil result[:renewal_date]
  end

  def test_verify_eligibility_omitted_coverage_dates_keep_defaults
    @adapter.add_coverage("pt_test_001", resource_type: "medicaid", coverage_end: nil)
    result = @adapter.verify_eligibility("pt_test_001", "medicaid")
    assert_equal Date.new(Date.current.year, 1, 1), result[:coverage_start]
    assert_nil result[:coverage_end]
    refute result.key?(:renewal_date)
  end

  def test_get_coverages_returns_eligibility_group_state_and_source_from_add_coverage
    @adapter.add_coverage(
      "pt_mcd_001",
      state: "XA",
      plan_name: "TEST SYNTHETIC PLAN",
      eligibility_group: "expansion_adult",
      eligibility_group_source: "eligibility_response"
    )

    coverages = @adapter.get_coverages("pt_mcd_001")
    assert_equal 1, coverages.size
    row = coverages.first
    assert_equal "XA", row[:state]
    assert_equal "TEST SYNTHETIC PLAN", row[:plan_name]
    assert_equal "expansion_adult", row[:eligibility_group]
    assert_equal "eligibility_response", row[:eligibility_group_source]
  end

  # -- Budget -----------------------------------------------------------------

  def test_get_budget_summary_returns_total_obligated_remaining
    summary = @adapter.get_budget_summary
    assert summary[:total]
    assert summary[:obligated]
    assert summary[:remaining]
  end

  # -- Reset for tests --------------------------------------------------------

  def test_reset_clears_all_state
    @adapter.add_patient("pt_001", display_name: "TEST", dob: nil, sex: nil, ssn_last4: nil)
    @adapter.store_text(case_token: "ct_x", kind: :note, text: "before reset")
    @adapter.reset!
    assert_nil @adapter.find_patient("pt_001")
  end

  # -- verify_tribal_enrollment contract: tribe_code + confidence ------------

  def test_verify_tribal_enrollment_returns_tribe_code_when_added_via_add_enrollment
    @adapter.add_enrollment("pt_e1", enrolled: true, tribe_name: "Demo Tribe", tribe_code: "DEMO", member_status: "enrolled")
    result = @adapter.verify_tribal_enrollment("pt_e1")
    assert_equal "DEMO", result[:tribe_code]
    assert_equal "Demo Tribe", result[:tribe_name]
    assert result[:enrolled]
  end

  def test_verify_tribal_enrollment_without_confidence_returns_unavailable
    @adapter.add_enrollment("pt_e2", enrolled: true, tribe_name: "T", tribe_code: "T")
    result = @adapter.verify_tribal_enrollment("pt_e2")
    assert_equal :unavailable, result[:confidence]
  end

  def test_verify_tribal_enrollment_propagates_explicit_confidence_verified
    @adapter.add_enrollment("pt_e2v", enrolled: true, tribe_name: "T", tribe_code: "T", confidence: :verified)
    result = @adapter.verify_tribal_enrollment("pt_e2v")
    assert_equal :verified, result[:confidence]

    @adapter.add_enrollment("pt_e2b", enrolled: true, tribe_name: "T", tribe_code: "T")
    result_without_confidence = @adapter.verify_tribal_enrollment("pt_e2b")
    refute_equal :verified, result_without_confidence[:confidence]
  end

  def test_verify_tribal_enrollment_confidence_outside_allow_list_is_unavailable
    [ :VERIFIED, :unverified, "Verified", " verified", "", nil, true, 1 ].each_with_index do |raw, index|
      @adapter.add_enrollment("pt_conf_#{index}", enrolled: true, tribe_name: "T", tribe_code: "T", confidence: raw)
      assert_equal :unavailable, @adapter.verify_tribal_enrollment("pt_conf_#{index}")[:confidence], raw.inspect
    end
  end

  def test_verify_tribal_enrollment_propagates_explicit_confidence_stale
    @adapter.add_enrollment("pt_e3", enrolled: true, tribe_name: "T", tribe_code: "T", confidence: :stale)
    result = @adapter.verify_tribal_enrollment("pt_e3")
    assert_equal :stale, result[:confidence]
  end

  def test_verify_tribal_enrollment_unknown_patient_returns_nil_enrolled_with_unavailable_confidence
    result = @adapter.verify_tribal_enrollment("pt_unknown")
    assert_nil result[:enrolled]
    assert_nil result[:tribe_code]
    assert_equal :unavailable, result[:confidence]
  end

  def test_verify_tribal_enrollment_seeded_not_enrolled_record_returns_verified_confidence
    @adapter.add_enrollment("pt_ne", enrolled: false, tribe_name: nil, tribe_code: nil, member_status: "denied",
                            confidence: :verified)
    result = @adapter.verify_tribal_enrollment("pt_ne")
    refute result[:enrolled]
    assert_equal :verified, result[:confidence]
  end

  # -- ADR 0003: MockAdapter is not a security boundary ----------------------

  def test_mock_adapter_documents_it_is_not_a_security_boundary
    # MockAdapter should be flagged in source as dev/test only.
    source = File.read(File.expand_path("../../../lib/corvid/adapters/mock_adapter.rb", __dir__))
    assert_match(/not a security boundary/i, source)
  end

  # -- Conditions / medications (issue #611) ----------------------------------

  def test_add_condition_and_get_conditions_round_trip
    ref = Corvid::ConditionReference.new(
      code: "C001", code_system: "http://example.test/codes", display: "TEST CONDITION 001",
      clinical_status: "active", category: "problem-list-item", onset_date: Date.new(2020, 3, 15)
    )
    @adapter.add_condition("pt_001", ref)
    result = @adapter.get_conditions("pt_001")
    assert_equal 1, result.size
    assert_equal ref, result.first
  end

  def test_get_conditions_returns_empty_when_none_seeded
    assert_respond_to @adapter, :add_condition
    assert_equal [], @adapter.get_conditions("pt_001")
  end

  def test_reset_clears_conditions
    ref = Corvid::ConditionReference.new(
      code: "C001", code_system: "http://example.test/codes", display: "TEST CONDITION 001",
      clinical_status: "resolved", category: "encounter-diagnosis", onset_date: nil
    )
    @adapter.add_condition("pt_001", ref)
    @adapter.reset!
    assert_equal [], @adapter.get_conditions("pt_001")
  end

  def test_add_medication_and_get_medications_round_trip
    ref = Corvid::MedicationReference.new(
      code: "M001", code_system: "http://example.test/rxnorm", display: "TEST MEDICATION 001",
      status: "active", authored_on: Date.new(2024, 6, 1), dosage_text: "TEST DOSAGE 001"
    )
    @adapter.add_medication("pt_001", ref)
    result = @adapter.get_medications("pt_001")
    assert_equal 1, result.size
    assert_equal ref, result.first
  end

  def test_get_medications_returns_empty_when_none_seeded
    assert_respond_to @adapter, :add_medication
    assert_equal [], @adapter.get_medications("pt_001")
  end

  def test_reset_clears_medications
    ref = Corvid::MedicationReference.new(
      code: "M001", code_system: "http://example.test/rxnorm", display: "TEST MEDICATION 001",
      status: "stopped", authored_on: nil, dosage_text: nil
    )
    @adapter.add_medication("pt_001", ref)
    @adapter.reset!
    assert_equal [], @adapter.get_medications("pt_001")
  end

  def test_add_condition_raises_unless_given_condition_reference
    error = assert_raises(ArgumentError) { @adapter.add_condition("pt_001", { code: "C001" }) }
    assert_match(/ConditionReference/i, error.message)
  end

  def test_add_medication_raises_unless_given_medication_reference
    error = assert_raises(ArgumentError) { @adapter.add_medication("pt_001", { code: "M001" }) }
    assert_match(/MedicationReference/i, error.message)
  end

  def test_get_conditions_returns_copy_not_internal_storage
    ref = Corvid::ConditionReference.new(
      code: "C001", code_system: "http://example.test/codes", display: "TEST CONDITION 001",
      clinical_status: "active", category: "problem-list-item", onset_date: nil
    )
    @adapter.add_condition("pt_001", ref)
    returned = @adapter.get_conditions("pt_001")
    returned.clear
    assert_equal 1, @adapter.get_conditions("pt_001").size
  end

  def test_get_medications_returns_copy_not_internal_storage
    ref = Corvid::MedicationReference.new(
      code: "M001", code_system: "http://example.test/rxnorm", display: "TEST MEDICATION 001",
      status: "active", authored_on: nil, dosage_text: nil
    )
    @adapter.add_medication("pt_001", ref)
    returned = @adapter.get_medications("pt_001")
    returned.clear
    assert_equal 1, @adapter.get_medications("pt_001").size
  end

  # -- Issue #611 panel round 2 ------------------------------------------------

  def test_get_conditions_returns_nil_for_nil_patient_identifier
    assert_nil @adapter.get_conditions(nil)
  end

  def test_get_conditions_returns_nil_for_blank_patient_identifier
    assert_nil @adapter.get_conditions("   ")
  end

  def test_get_medications_returns_nil_for_nil_patient_identifier
    assert_nil @adapter.get_medications(nil)
  end

  def test_get_medications_returns_nil_for_blank_patient_identifier
    assert_nil @adapter.get_medications("")
  end

  # -- Issue #611 panel round 4: returned reference strings are immutable ------

  def test_get_conditions_returned_display_is_frozen_or_unchanged_on_next_call
    ref = Corvid::ConditionReference.new(
      code: "C001", code_system: "http://example.test/codes", display: +"TEST CONDITION 001",
      clinical_status: "active", category: "problem-list-item", onset_date: nil
    )
    @adapter.add_condition("pt_001", ref)
    first = @adapter.get_conditions("pt_001").first
    expected_display = "TEST CONDITION 001"

    if first.display.frozen?
      assert first.display.frozen?
    else
      first.display << "X"
      second = @adapter.get_conditions("pt_001").first
      assert_equal expected_display, second.display
    end
  end

  def test_get_medications_returned_display_is_frozen_or_unchanged_on_next_call
    ref = Corvid::MedicationReference.new(
      code: "M001", code_system: "http://example.test/rxnorm", display: +"TEST MEDICATION 001",
      status: "active", authored_on: nil, dosage_text: +"TEST DOSAGE 001"
    )
    @adapter.add_medication("pt_001", ref)
    first = @adapter.get_medications("pt_001").first
    expected_display = "TEST MEDICATION 001"

    if first.display.frozen?
      assert first.display.frozen?
    else
      first.display << "X"
      second = @adapter.get_medications("pt_001").first
      assert_equal expected_display, second.display
    end
  end

  def test_instantiating_mock_adapter_does_not_change_time_zone
    saved = Time.zone
    Time.zone = "Pacific/Honolulu"
    begin
      Corvid::Adapters::MockAdapter.new
      assert_equal "Pacific/Honolulu", Time.zone.tzinfo.name,
                   "MockAdapter must not assign Time.zone (issue #712 R10)"
    ensure
      Time.zone = saved
    end
  end

  def test_loading_mock_adapter_does_not_assign_time_zone_when_zone_is_already_set
    adapter_path = File.expand_path("../../../lib/corvid/adapters/mock_adapter.rb", __dir__)
    script = <<~RUBY
      require "active_support/all"
      Time.zone = "Pacific/Honolulu"
      load #{adapter_path.inspect}
      puts Time.zone.tzinfo.name
    RUBY
    output, = capture_mock_adapter_load_subprocess(script)
    zone_name = output.strip
    assert_equal "Pacific/Honolulu", zone_name,
                 "mock_adapter.rb must not assign Time.zone on load (issue #712 R10); child output: #{output}"
  end

  def test_loading_mock_adapter_leaves_time_zone_nil_when_it_was_nil
    adapter_path = File.expand_path("../../../lib/corvid/adapters/mock_adapter.rb", __dir__)
    script = <<~RUBY
      require "active_support/all"
      load #{adapter_path.inspect}
      puts(Time.zone.nil? ? "nil" : Time.zone.tzinfo.name)
    RUBY
    output, = capture_mock_adapter_load_subprocess(script)
    zone_label = output.strip
    assert_equal "nil", zone_label,
                 "mock_adapter.rb must not default Time.zone to UTC on load (issue #712 R10); child output: #{output}"
  end

  def test_verify_eligibility_false_when_coverage_end_before_inquiry_date
    @adapter.add_coverage(
      "pt-712-inquiry",
      coverage_type: "medicaid",
      eligible: true,
      coverage_start: Date.new(2026, 1, 1),
      coverage_end: Date.new(2026, 9, 30)
    )

    result = @adapter.verify_eligibility("pt-712-inquiry", "medicaid", date_of_service: Date.new(2026, 10, 15))
    refute result[:eligible], "Coverage ending before inquiry must not be eligible (issue #712 R9)"
  end

  def test_verify_eligibility_true_when_coverage_covers_inquiry_date
    @adapter.add_coverage(
      "pt-712-inquiry",
      coverage_type: "medicaid",
      eligible: true,
      coverage_start: Date.new(2026, 1, 1),
      coverage_end: Date.new(2026, 9, 30)
    )

    result = @adapter.verify_eligibility("pt-712-inquiry", "medicaid", date_of_service: Date.new(2026, 9, 15))
    assert result[:eligible]
  end

  # -- Issue #712: date_of_service on eligibility reads ----------------------------

  def test_verify_eligibility_without_date_of_service_sets_defaulted_flag
    assert @adapter.method(:verify_eligibility).parameters.any? { |type, name|
      type == :key && name == :date_of_service
    }, "verify_eligibility must accept date_of_service: keyword (issue #712)"

    @adapter.add_coverage(
      "pt-712-001",
      coverage_type: "medicaid",
      payer_name: "MOCK MEDICAID PAYER",
      plan_name: "TEST PLAN 712",
      eligible: true
    )

    travel_to Time.zone.local(2026, 10, 27, 9, 0, 0) do
      result = @adapter.verify_eligibility("pt-712-001", "medicaid")
      assert_equal Date.new(2026, 10, 27), result[:date_of_service]
      assert result[:date_of_service_defaulted]
    end
  end

  def test_verify_eligibility_with_explicit_date_of_service_clears_defaulted_flag
    assert @adapter.method(:verify_eligibility).parameters.any? { |type, name|
      type == :key && name == :date_of_service
    }, "verify_eligibility must accept date_of_service: keyword (issue #712)"

    @adapter.add_coverage(
      "pt-712-001",
      coverage_type: "medicaid",
      payer_name: "MOCK MEDICAID PAYER",
      plan_name: "TEST PLAN 712",
      eligible: true
    )
    explicit = Date.new(2026, 10, 15)

    result = @adapter.verify_eligibility("pt-712-001", "medicaid", date_of_service: explicit)

    assert_equal explicit, result[:date_of_service]
    refute result[:date_of_service_defaulted]
  end

  def test_verify_eligibility_rejects_non_date_date_of_service
    params = @adapter.method(:verify_eligibility).parameters
    assert params.any? { |type, name| type == :key && name == :date_of_service },
           "verify_eligibility must accept date_of_service: keyword (issue #712)"

    @adapter.add_coverage("pt-712-001", coverage_type: "medicaid", eligible: true)

    assert_raises(ArgumentError) do
      @adapter.verify_eligibility("pt-712-001", "medicaid", date_of_service: "2026-10-15")
    end
  end

  # -- Issue #712: MockAdapter eligibility scenarios -----------------------------

  SCENARIO_PATIENT = "pt-712-scenario"

  def test_seed_medicaid_eligibility_scenario_active_this_month_only
    assert_respond_to @adapter, :seed_medicaid_eligibility_scenario

    inquiry = Date.new(2026, 10, 20)
    @adapter.seed_medicaid_eligibility_scenario(SCENARIO_PATIENT, :active_this_month_only)
    result = @adapter.verify_eligibility(SCENARIO_PATIENT, "medicaid", date_of_service: inquiry)

    assert result[:eligible]
    assert_equal Date.new(2026, 10, 31), result[:coverage_end]
    assert_equal inquiry, result[:date_of_service]
  end

  def test_seed_medicaid_eligibility_scenario_mid_month_end
    assert_respond_to @adapter, :seed_medicaid_eligibility_scenario

    inquiry = Date.new(2026, 10, 20)
    @adapter.seed_medicaid_eligibility_scenario(SCENARIO_PATIENT, :mid_month_end)
    result = @adapter.verify_eligibility(SCENARIO_PATIENT, "medicaid", date_of_service: inquiry)

    assert result[:eligible]
    assert_equal Date.new(2026, 10, 1), result[:coverage_start],
                 "mid_month_end must start coverage on the first of the inquiry month (issue #712 R12)"
    assert_equal Date.new(2026, 10, 14), result[:coverage_end]
  end

  def test_seed_medicaid_eligibility_scenario_placeholder_end
    assert_respond_to @adapter, :seed_medicaid_eligibility_scenario

    inquiry = Date.new(2026, 10, 1)
    @adapter.seed_medicaid_eligibility_scenario(SCENARIO_PATIENT, :placeholder_end)
    result = @adapter.verify_eligibility(SCENARIO_PATIENT, "medicaid", date_of_service: inquiry)

    assert result[:eligible]
    assert_equal Date.new(9999, 12, 31), result[:coverage_end]
  end

  def test_seed_medicaid_eligibility_scenario_inactive_with_covering_dates
    assert_respond_to @adapter, :seed_medicaid_eligibility_scenario

    inquiry = Date.new(2026, 10, 10)
    @adapter.seed_medicaid_eligibility_scenario(SCENARIO_PATIENT, :inactive_with_covering_dates)
    result = @adapter.verify_eligibility(SCENARIO_PATIENT, "medicaid", date_of_service: inquiry)

    assert result[:eligible], "inactive service scenario still has covering plan dates at payer level"
    assert_equal false, result[:service_active]
  end

  def capture_mock_adapter_load_subprocess(script)
    lib_dir = File.expand_path("../../../lib", __dir__)
    Open3.capture2e(RbConfig.ruby, "-I", lib_dir, "-e", script)
  end
  private :capture_mock_adapter_load_subprocess
end
