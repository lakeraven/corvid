# frozen_string_literal: true

require "minitest/autorun"
require "corvid"
require "corvid/rcm"
require_relative "claim_factory"
require_relative "edi_271_test_helper"

class Corvid::Rcm::FixtureClearinghouseClientTest < Minitest::Test
  include Corvid::Rcm::Edi271TestHelper

  Factory = Corvid::Rcm::ClaimFactory
  FIXED_CLOCK = -> { Time.utc(2026, 9, 1, 12, 0, 0) }

  def setup
    @client = Corvid::Rcm::FixtureClearinghouseClient.new(clock: FIXED_CLOCK)
  end

  # -- the interface ---------------------------------------------------------

  def test_it_implements_the_clearinghouse_client_interface
    assert_kind_of Corvid::Rcm::ClearinghouseClient, @client
  end

  def test_the_interface_itself_refuses_to_pretend_it_works
    bare = Corvid::Rcm::ClearinghouseClient.new

    assert_raises(NotImplementedError) { bare.submit_claim(Factory.claim) }
    assert_raises(NotImplementedError) { bare.fetch_remittances }
    assert_raises(NotImplementedError) { bare.check_eligibility(eligibility_inquiry) }
  end

  # -- submission ------------------------------------------------------------

  def test_a_clean_claim_is_acknowledged_as_accepted
    ack = @client.submit_claim(Factory.claim)

    assert ack.accepted?
    refute ack.rejected?
    assert_equal "CLM-2001", ack.claim_identifier
    assert_equal "ACK-CLM-2001", ack.trace_number
    assert_equal :awaiting_adjudication, ack.disposition
    assert_empty ack.edits
  end

  def test_an_acceptance_is_not_a_payment_decision
    ack = @client.submit_claim(Factory.claim)

    refute_respond_to ack, :denied?, "an acknowledgment must never answer a denial question"
    assert_nil ack.work_queue
  end

  def test_submission_is_deterministic
    first = @client.submit_claim(Factory.claim)
    second = Corvid::Rcm::FixtureClearinghouseClient.new(clock: FIXED_CLOCK).submit_claim(Factory.claim)

    assert_equal first, second
  end

  def test_submitted_claims_are_recorded_in_order
    @client.submit_claim(Factory.claim(identifier: "CLM-A"))
    @client.submit_claim(Factory.claim(identifier: "CLM-B"))

    assert_equal %w[CLM-A CLM-B], @client.submitted.map(&:identifier)
  end

  # -- rejection (never adjudicated, never a denial) -------------------------

  def test_a_canned_277ca_rejection_routes_to_rework_not_appeal
    ack = @client.submit_claim(Factory.claim(identifier: "CLM-RJ-0001"))

    assert ack.rejected?
    assert_equal "277CA", ack.transaction_set
    assert_equal :fix_and_resubmit, ack.disposition
    assert_equal :claim_rework, ack.work_queue
    assert_match(/billing provider NPI is not on file/, ack.reasons.first)
  end

  def test_a_999_syntax_rejection_is_still_a_rejection
    ack = @client.submit_claim(Factory.claim(identifier: "CLM-RJ-0002"))

    assert ack.rejected?
    assert_equal "999", ack.transaction_set
    assert_equal :fix_and_resubmit, ack.disposition
  end

  def test_a_rejection_can_carry_several_edits
    ack = @client.submit_claim(Factory.claim(identifier: "CLM-RJ-0003"))

    assert_equal 2, ack.edits.length
    assert_equal %w[A3:21 A3:249], ack.edits.map(&:code)
  end

  def test_a_claim_with_no_billing_provider_npi_is_rejected_at_the_front_door
    ack = @client.submit_claim(Factory.claim(billing_provider_npi: nil))

    assert ack.rejected?
    assert_match(/billing provider NPI is missing/, ack.reasons.first)
  end

  def test_an_unknown_outcome_cannot_be_constructed
    assert_raises(ArgumentError) do
      Corvid::Rcm::Acknowledgment.new(claim_identifier: "X", trace_number: "Y", outcome: :denied)
    end
  end

  # -- remittances -----------------------------------------------------------

  def test_it_returns_every_scenario_in_a_stable_order
    identifiers = @client.fetch_remittances.map(&:remittance_identifier)

    assert_equal Corvid::Rcm::FixtureClearinghouseClient::SCENARIOS.length, identifiers.length
    assert_equal identifiers, @client.fetch_remittances.map(&:remittance_identifier)
  end

  def test_it_covers_every_required_phase_0_scenario
    codes = @client.fetch_remittances.flat_map { |rem| rem.claims.flat_map(&:adjustment_codes) }.uniq

    %w[CO-45 PR-1 PR-2 PR-3 CO-16 CO-18 CO-29 CO-50 CO-97 CO-197 CO-234].each do |code|
      assert_includes codes, code
    end
  end

  # Same keyword as `Corvid::Adapters::Base#fetch_remittances`, so a caller
  # written against the adapter contract is not refused with ArgumentError.
  def test_remittances_can_be_filtered_by_a_payment_date_range
    assert_empty @client.fetch_remittances(date_range: Date.new(2026, 10, 1)..Date.new(2026, 10, 31))
    refute_empty @client.fetch_remittances(date_range: Date.new(2026, 9, 1)..Date.new(2026, 9, 30))
    refute_empty @client.fetch_remittances(date_range: Date.new(2026, 9, 1)..)
  end

  def test_the_seam_takes_the_same_keyword_as_the_adapter_contract
    seam = Corvid::Rcm::ClearinghouseClient.instance_method(:fetch_remittances).parameters
    adapter = Corvid::Adapters::Base.instance_method(:fetch_remittances).parameters

    assert_equal adapter, seam
  end

  def test_a_single_scenario_can_be_fetched_by_name
    remittance = @client.remittance("denial_duplicate_co18")

    assert_equal [ "CO-18" ], remittance.claims.first.adjustment_codes
  end

  def test_an_unknown_scenario_fails_loudly
    assert_raises(ArgumentError) { @client.remittance("no_such_scenario") }
  end

  def test_the_scenario_list_can_be_narrowed
    client = Corvid::Rcm::FixtureClearinghouseClient.new(scenarios: %w[clean_full_pay], clock: FIXED_CLOCK)

    assert_equal 1, client.fetch_remittances.length
  end

  # -- the two vocabularies stay apart ---------------------------------------

  def test_a_denial_arrives_on_the_835_and_a_rejection_never_does
    denial = @client.remittance("denial_medical_necessity_co50").claims.first

    assert denial.adjudicated?
    assert denial.denied?

    rejection = @client.submit_claim(Factory.claim(identifier: "CLM-RJ-0001"))
    refute_respond_to rejection, :adjudicated?
  end

  # -- eligibility (271 fixtures keyed by member identifier, #736) -----------

  MEMBER_ACTIVE_COMMERCIAL = "MBR-ACTIVE-COMMERCIAL"
  MEMBER_INACTIVE = "MBR-INACTIVE"
  MEMBER_MEDICAID_OPEN = "MBR-MEDICAID-OPEN"
  MEMBER_AAA72 = "MBR-AAA72"
  MEMBER_AAA42 = "MBR-AAA42"
  MEMBER_AAA_UNMAPPED = "MBR-AAA-UNMAPPED"
  MEMBER_UNKNOWN = "MBR-NOT-IN-FIXTURE-TABLE"

  def eligibility_inquiry(**overrides)
    Corvid::Rcm::EligibilityInquiry.new(**{
      patient_identifier: "pt_elig_0001",
      payer_identifier: "EXPAYER01",
      member_identifier: MEMBER_ACTIVE_COMMERCIAL,
      service_date: Factory::SERVICE_DATE,
      provider_npi: Factory::BILLING_NPI
    }.merge(overrides))
  end

  def check(member_identifier, **overrides)
    @client.check_eligibility(eligibility_inquiry(member_identifier: member_identifier, **overrides))
  end

  def test_active_commercial_member_returns_active_with_plan_and_benefit_detail
    response = check(MEMBER_ACTIVE_COMMERCIAL)

    assert_equal :active, response.outcome
    assert_equal FIXED_CLOCK.call, response.as_of

    plan = response.plans.first
    refute_nil plan
    assert plan.payer_identifier.to_s.strip != "", "expected a payer_identifier on the plan"
    assert plan.plan_name.to_s.strip != "", "expected a plan_name on the plan"
    assert plan.group_number.to_s.strip != "", "expected a group_number on the plan"
    assert_kind_of Date, plan.coverage_start
    assert_kind_of Date, plan.coverage_end
    refute_equal Date.new(9999, 12, 31), plan.coverage_end

    benefit = plan.benefits.find { |b| b.service_type_code == "30" }
    refute_nil benefit, "expected at least one benefit for service type 30"
  end

  def test_inactive_member_returns_inactive_outcome
    assert_equal :inactive, check(MEMBER_INACTIVE).outcome
  end

  def test_medicaid_open_end_coverage_returns_active_with_nil_coverage_end
    response = check(MEMBER_MEDICAID_OPEN)
    plan = response.plans.first

    assert_equal :active, response.outcome
    refute_nil plan
    assert_kind_of Date, plan.coverage_start
    assert_nil plan.coverage_end
  end

  def test_aaa_72_invalid_member_returns_undetermined_with_error_code_72
    response = check(MEMBER_AAA72)

    assert_equal :undetermined, response.outcome
    error = response.errors.find { |e| e.code == "72" }
    refute_nil error
    assert error.description.to_s.strip != "", "expected a description for AAA 72"
  end

  def test_aaa_42_payer_unavailable_returns_undetermined_with_error_code_42
    response = check(MEMBER_AAA42)

    assert_equal :undetermined, response.outcome
    error = response.errors.find { |e| e.code == "42" }
    refute_nil error
  end

  def test_unmapped_aaa_code_returns_undetermined_not_inactive
    response = check(MEMBER_AAA_UNMAPPED)

    assert_equal :undetermined, response.outcome
    refute_equal :inactive, response.outcome

    error_99 = response.errors.find { |entry| entry.code == "99" }
    refute_nil error_99, "expected AAA reject code 99 on the response"
    assert error_99.description.to_s.strip != "", "expected a non-empty description for code 99"

    error_72 = response.errors.find { |entry| entry.code == "72" }
    aaa72_description = error_72&.description || Corvid::Rcm::Edi271Reader::AAA_REJECT_REASONS.fetch("72")
    refute_equal aaa72_description, error_99.description
  end

  def test_unknown_member_identifier_returns_undetermined_without_raising
    response = check(MEMBER_UNKNOWN)

    assert_equal :undetermined, response.outcome
  end

  def test_nil_member_identifier_returns_undetermined
    response = @client.check_eligibility(eligibility_inquiry(member_identifier: nil))

    assert_equal :undetermined, response.outcome
  end

  def test_eligibility_as_of_comes_from_the_injected_clock
    clock = -> { Time.utc(2025, 3, 15, 8, 30, 0) }
    client = Corvid::Rcm::FixtureClearinghouseClient.new(clock: clock)
    response = client.check_eligibility(eligibility_inquiry(member_identifier: MEMBER_ACTIVE_COMMERCIAL))

    assert_equal clock.call, response.as_of
  end

  def test_service_date_on_the_inquiry_is_available_to_fixture_lookup
    on_date = Date.new(2026, 6, 1)
    inquiry = eligibility_inquiry(member_identifier: MEMBER_ACTIVE_COMMERCIAL, service_date: on_date)
    response = @client.check_eligibility(inquiry)

    assert_equal on_date, inquiry.service_date
    assert_equal :active, response.outcome
  end

  def test_unknown_is_never_no_only_explicit_inactive_is_inactive
    scenarios = [
      MEMBER_ACTIVE_COMMERCIAL,
      MEMBER_MEDICAID_OPEN,
      MEMBER_AAA72,
      MEMBER_AAA42,
      MEMBER_AAA_UNMAPPED,
      MEMBER_UNKNOWN
    ]

    scenarios.each do |member|
      outcome = check(member).outcome
      refute_equal :inactive, outcome, "member #{member.inspect} must not read as inactive"
    end

    assert_equal :undetermined, @client.check_eligibility(eligibility_inquiry(member_identifier: nil)).outcome
    assert_equal :inactive, check(MEMBER_INACTIVE).outcome
  end

  # -- service-type-scoped outcomes (271 tmp fixtures) -----------------------

  def test_pharmacy_inactive_only_is_undetermined_when_plan_coverage_was_asked
    with_member_fixture("MBR-SYNTH-PHARM-INACTIVE", [ "EB*6*IND*88" ]) do |member|
      response = check_in_dir(@fixture_dir, member)

      assert_equal :undetermined, response.outcome
      refute_equal :inactive, response.outcome
    end
  end

  def test_pharmacy_active_only_is_undetermined_when_plan_coverage_was_asked
    with_member_fixture("MBR-SYNTH-PHARM-ACTIVE", [ "EB*1*IND*88" ]) do |member|
      response = check_in_dir(@fixture_dir, member)

      assert_equal :undetermined, response.outcome
      refute_equal :active, response.outcome
    end
  end

  def test_plan_active_eb_for_service_type_30_returns_active
    with_member_fixture("MBR-SYNTH-PLAN-ACTIVE", [ "EB*1*IND*30" ]) do |member|
      assert_equal :active, check_in_dir(@fixture_dir, member).outcome
    end
  end

  def test_plan_active_eb_with_composite_service_types_including_30_returns_active
    with_member_fixture("MBR-SYNTH-PLAN-COMPOSITE", [ "EB*1*IND*30^88" ]) do |member|
      assert_equal :active, check_in_dir(@fixture_dir, member).outcome
    end
  end

  def test_blank_eb03_counts_for_plan_coverage_when_30_was_asked
    with_member_fixture("MBR-SYNTH-BLANK-EB03", [ "EB*1*IND" ]) do |member|
      assert_equal :active, check_in_dir(@fixture_dir, member, service_type_codes: %w[30]).outcome
    end
  end

  def test_blank_eb03_is_undetermined_when_only_pharmacy_was_asked
    with_member_fixture("MBR-SYNTH-BLANK-EB03-PHARM", [ "EB*1*IND" ]) do |member|
      assert_equal :undetermined, check_in_dir(@fixture_dir, member, service_type_codes: %w[88]).outcome
    end
  end

  def test_conflicting_active_and_inactive_across_asked_service_types_is_undetermined
    with_member_fixture(
      "MBR-SYNTH-CONFLICT-MULTI-ASK",
      [ "EB*1*IND*30", "EB*6*IND*88" ]
    ) do |member|
      response = check_in_dir(@fixture_dir, member, service_type_codes: %w[30 88])

      assert_equal :undetermined, response.outcome
    end
  end

  def test_inactive_pharmacy_with_unrelated_plan_active_returns_inactive_when_pharmacy_was_asked
    with_member_fixture(
      "MBR-SYNTH-PHARM-INACTIVE-PLAN-ACTIVE",
      [ "EB*1*IND*30", "EB*6*IND*88" ]
    ) do |member|
      assert_equal :inactive, check_in_dir(@fixture_dir, member, service_type_codes: %w[88]).outcome
    end
  end

  # -- fail-closed (each scenario stands alone) ------------------------------

  def test_active_plan_with_aaa_72_is_undetermined_and_surfaces_error_72
    with_member_fixture("MBR-SYNTH-AAA72-MIXED", [ "EB*1*IND*30", "AAA*N**72*C" ]) do |member|
      response = check_in_dir(@fixture_dir, member)

      assert_equal :undetermined, response.outcome
      refute_nil response.errors.find { |entry| entry.code == "72" }
    end
  end

  def test_active_and_inactive_plan_coverage_together_is_undetermined
    with_member_fixture("MBR-SYNTH-PLAN-BOTH", [ "EB*1*IND*30", "EB*6*IND*30" ]) do |member|
      assert_equal :undetermined, check_in_dir(@fixture_dir, member).outcome
    end
  end

  def test_inactive_variant_eb08_for_plan_coverage_is_undetermined
    with_member_fixture("MBR-SYNTH-EB08", [ "EB*8*IND*30" ]) do |member|
      assert_equal :undetermined, check_in_dir(@fixture_dir, member).outcome
    end
  end

  def test_copay_eb_alone_does_not_answer_coverage
    with_member_fixture("MBR-SYNTH-COPAY-ONLY", [ "EB*B*IND*30***27*25*****Y" ]) do |member|
      assert_equal :undetermined, check_in_dir(@fixture_dir, member).outcome
    end
  end

  def test_well_formed_271_without_eb_or_aaa_is_undetermined
    with_member_fixture("MBR-SYNTH-NO-EB", [ "REF*6P*GRP-SYNTH-NO-EB" ]) do |member|
      assert_equal :undetermined, check_in_dir(@fixture_dir, member).outcome
    end
  end

  # -- service date vs coverage window ---------------------------------------

  def test_service_date_after_coverage_end_is_undetermined
    body = [ "DTP*346*D8*20250101", "DTP*347*D8*20250630", "EB*1*IND*30" ]
    with_member_fixture("MBR-SYNTH-DATE-AFTER-END", body) do |member|
      response = check_in_dir(
        @fixture_dir,
        member,
        service_date: Date.new(2026, 3, 1)
      )

      assert_equal :undetermined, response.outcome
    end
  end

  def test_service_date_inside_coverage_window_returns_active
    body = [ "DTP*346*D8*20250101", "DTP*347*D8*20250630", "EB*1*IND*30" ]
    with_member_fixture("MBR-SYNTH-DATE-INSIDE", body) do |member|
      response = check_in_dir(
        @fixture_dir,
        member,
        service_date: Date.new(2025, 3, 1)
      )

      assert_equal :active, response.outcome
    end
  end

  def test_service_date_before_coverage_start_is_undetermined
    body = [ "DTP*346*D8*20250101", "DTP*347*D8*20250630", "EB*1*IND*30" ]
    with_member_fixture("MBR-SYNTH-DATE-BEFORE-START", body) do |member|
      response = check_in_dir(
        @fixture_dir,
        member,
        service_date: Date.new(2024, 12, 31)
      )

      assert_equal :undetermined, response.outcome
    end
  end

  def test_open_ended_coverage_end_with_service_date_after_start_returns_active
    body = [ "DTP*346*D8*20250101", "DTP*357*D8*99991231", "EB*1*IND*30" ]
    with_member_fixture("MBR-SYNTH-OPEN-END", body) do |member|
      response = check_in_dir(
        @fixture_dir,
        member,
        service_date: Date.new(2026, 3, 1)
      )

      assert_equal :active, response.outcome
    end
  end

  def test_missing_plan_dates_skip_service_date_window_check
    with_member_fixture("MBR-SYNTH-NO-DATES", [ "EB*1*IND*30" ]) do |member|
      response = check_in_dir(
        @fixture_dir,
        member,
        service_date: Date.new(1999, 1, 1)
      )

      assert_equal :active, response.outcome
    end
  end

  # -- dependent loop outcomes ------------------------------------------------

  def test_dependent_loop_without_coverage_eb_is_undetermined_even_if_subscriber_is_active
    body = [
      "EB*1*IND*30",
      "HL*4*3*23*0",
      "NM1*03*1******MI*MBR-SYNTH-DEP-CHILD"
    ]
    with_member_fixture(
      "MBR-SYNTH-DEP-UNDETERMINED",
      body,
      subscriber_hl_has_child: true
    ) do |member|
      assert_equal :undetermined, check_in_dir(@fixture_dir, member).outcome
    end
  end

  def test_dependent_loop_active_plan_coverage_returns_active
    body = [
      "HL*4*3*23*0",
      "NM1*03*1******MI*MBR-SYNTH-DEP-ACTIVE",
      "EB*1*IND*30"
    ]
    with_member_fixture(
      "MBR-SYNTH-DEP-ACTIVE",
      body,
      subscriber_hl_has_child: true
    ) do |member|
      assert_equal :active, check_in_dir(@fixture_dir, member).outcome
    end
  end

  def test_more_than_one_subscriber_hl_loop_in_one_transaction_is_undetermined
    content = build_271_transaction(
      member_token: "MBR-SYNTH-TWO-SUBS-A",
      segments_after_subscriber: [
        "EB*1*IND*30",
        "HL*4*2*22*0",
        "NM1*IL*1******MI*MBR-SYNTH-TWO-SUBS-B",
        "EB*1*IND*30"
      ],
      st_control: "9401"
    )
    with_written_fixture("MBR-SYNTH-TWO-SUBS-A", content) do |member|
      assert_equal :undetermined, check_in_dir(@fixture_dir, member).outcome
    end
  end

  def test_more_than_one_dependent_hl_loop_in_one_transaction_is_undetermined
    content = build_271(
      member_token: "MBR-SYNTH-TWO-DEPS-PARENT",
      subscriber_hl_has_child: true,
      body_after_subscriber: [
        "HL*4*3*23*1",
        "NM1*03*1******MI*MBR-SYNTH-TWO-DEPS-ONE",
        "EB*1*IND*30",
        "HL*5*4*23*0",
        "NM1*03*1******MI*MBR-SYNTH-TWO-DEPS-TWO",
        "EB*1*IND*30"
      ],
      st_control: "9402"
    )
    with_written_fixture("MBR-SYNTH-TWO-DEPS-PARENT", content) do |member|
      assert_equal :undetermined, check_in_dir(@fixture_dir, member).outcome
    end
  end

  # -- member identifier robustness (default fixture dir) --------------------

  def test_member_identifier_with_path_traversal_is_undetermined
    assert_equal :undetermined, check("../271/#{MEMBER_INACTIVE}").outcome
  end

  def test_member_identifier_with_embedded_path_traversal_is_undetermined
    assert_equal :undetermined, check("#{MEMBER_INACTIVE}/../#{MEMBER_INACTIVE}").outcome
  end

  def test_member_identifier_with_leading_space_is_undetermined
    assert_equal :undetermined, check(" #{MEMBER_INACTIVE}").outcome
  end

  def test_member_identifier_with_trailing_newline_is_undetermined
    assert_equal :undetermined, check("#{MEMBER_INACTIVE}\n").outcome
  end

  def test_member_identifier_with_a_dot_is_undetermined
    assert_equal :undetermined, check("MBR.INACTIVE").outcome
  end

  def test_symlink_to_a_fixture_outside_the_eligibility_directory_is_undetermined
    Dir.mktmpdir do |dir|
      target = File.expand_path(
        "../../../lib/corvid/rcm/fixtures/271/#{MEMBER_ACTIVE_COMMERCIAL}.271",
        __dir__
      )
      link = File.join(dir, "#{MEMBER_ACTIVE_COMMERCIAL}.271")
      File.symlink(target, link)

      client = fixture_client(dir)
      response = client.check_eligibility(build_eligibility_inquiry(MEMBER_ACTIVE_COMMERCIAL))

      assert_equal :undetermined, response.outcome
    end
  end

  def test_check_eligibility_always_returns_an_eligibility_response
    response = check(MEMBER_ACTIVE_COMMERCIAL)

    assert_kind_of Corvid::Rcm::EligibilityResponse, response
  end

  private

  def with_member_fixture(member_token, body_segments, subscriber_hl_has_child: false, &block)
    content = build_271(
      member_token: member_token,
      body_after_subscriber: body_segments,
      subscriber_hl_has_child: subscriber_hl_has_child
    )
    with_written_fixture(member_token, content, &block)
  end

  def with_written_fixture(member_token, content)
    Dir.mktmpdir do |dir|
      @fixture_dir = dir
      write_fixture(dir, member_token, content)
      yield member_token
    end
  end
end
