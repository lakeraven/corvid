# frozen_string_literal: true

require "minitest/autorun"
require "corvid"
require "corvid/rcm"
require_relative "claim_factory"

class Corvid::Rcm::FixtureClearinghouseClientTest < Minitest::Test
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
end
