# frozen_string_literal: true

require "minitest/autorun"
require "securerandom"
require "fileutils"
require "yaml"
require "corvid"
require "corvid/rcm"
require_relative "claim_factory"

class Corvid::Rcm::FixtureClearinghouseClientTest < Minitest::Test
  Factory = Corvid::Rcm::ClaimFactory
  FIXED_CLOCK = -> { Time.utc(2026, 9, 1, 12, 0, 0) }

  # -- the interface ---------------------------------------------------------

  def test_it_implements_the_clearinghouse_client_interface
    assert_kind_of Corvid::Rcm::ClearinghouseClient, @client
  end

  def test_the_interface_itself_refuses_to_pretend_it_works
    bare = Corvid::Rcm::ClearinghouseClient.new

    assert_raises(NotImplementedError) { bare.submit_claim(Factory.claim) }
    assert_raises(NotImplementedError) { bare.fetch_remittances }
    assert_raises(NotImplementedError) { bare.check_claim_status("CLM-1") }
  end

  # -- claim status (277 STC, typed) -----------------------------------------

  INVALID_CLAIM_IDENTIFIER_MESSAGE = "claim_identifier must be a non-blank String"
  CATEGORY_DISAGREES_MESSAGE = Corvid::Rcm::ClaimStatus::CATEGORY_DISAGREES
  UNKNOWN_FIELD_MESSAGE = "canned claim status row has an unknown field"
  CATEGORY_CODE_STRING_MESSAGE = "category_code must be a String"
  PAID_AMOUNT_STRING_MESSAGE = "paid_amount must be a decimal string"
  INVALID_CALENDAR_DATE_MESSAGE = "paid_date is not a valid calendar date"

  def setup
    @tmpdir = Dir.mktmpdir("corvid-fixture-claim-status-")
    @client = Corvid::Rcm::FixtureClearinghouseClient.new(clock: FIXED_CLOCK)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir
  end

  def test_a_pending_claim_status_from_the_fixture_table
    status = @client.check_claim_status("CLM-ST-PENDING")

    assert_equal "CLM-ST-PENDING", status.claim_identifier
    assert_equal :pending, status.category
    assert_equal "P1", status.category_code
    refute_empty status.status_code.to_s.strip
    assert_nil status.paid_amount
    assert_nil status.raw_reference
    assert_equal FIXED_CLOCK.call, status.as_of
    assert status.pending?
    refute status.final?
  end

  def test_a_paid_claim_status_carries_exact_money_and_dates
    status = @client.check_claim_status("CLM-ST-PAID")

    assert_equal :finalized_paid, status.category
    assert_equal "F1", status.category_code
    assert_equal BigDecimal("125.40"), status.paid_amount
    assert_kind_of Date, status.paid_date
    refute_empty status.payer_control_number.to_s.strip
    refute_empty status.status_code.to_s.strip
    assert status.paid?
    assert status.final?
    refute status.denied?
    refute status.rejected?
  end

  def test_a_denied_claim_status_is_adjudicated_not_rejected
    status = @client.check_claim_status("CLM-ST-DENIED")

    assert_equal :finalized_denied, status.category
    assert_equal "F2", status.category_code
    assert_nil status.paid_amount
    refute_empty status.status_code.to_s.strip
    assert status.denied?
    refute status.rejected?, "adjudicated denial must stay separate from front-end rejection"
    assert status.final?
  end

  def test_a_rejected_claim_status_is_front_end_not_denied
    status = @client.check_claim_status("CLM-ST-REJECTED")

    assert_equal :rejected, status.category
    assert_equal "A7", status.category_code
    refute_empty status.status_code.to_s.strip
    assert status.rejected?
    refute status.denied?
    refute status.final?
  end

  def test_an_unknown_claim_identifier_is_not_found
    status = @client.check_claim_status("CLM-NOT-ON-FILE")

    assert_equal :not_found, status.category
    assert_equal "CLM-NOT-ON-FILE", status.claim_identifier
    assert_nil status.raw_reference
    assert_equal FIXED_CLOCK.call, status.as_of
  end

  def test_check_claim_status_rejects_blank_or_non_string_identifiers
    [ nil, "", "   ", 12_345 ].each do |bad|
      error = assert_raises(ArgumentError) { @client.check_claim_status(bad) }

      assert_equal INVALID_CLAIM_IDENTIFIER_MESSAGE, error.message
    end
  end

  # -- review round 1 (#740): canned claim-status table validation -----------

  def test_fixture_loader_refuses_a_yaml_float_paid_amount
    expected_row = {
      "category" => "finalized_paid",
      "category_code" => "F1",
      "status_code" => "65",
      "paid_amount" => 12_345_678_901_234_567.89,
      "paid_date" => nil
    }
    path = write_claim_status_table(<<~YAML, "SYN-740-FLOAT" => expected_row)
      SYN-740-FLOAT:
        category: finalized_paid
        category_code: "F1"
        status_code: "65"
        paid_amount: 12345678901234567.89
        paid_date: null
    YAML

    assert_fixture_load_refusal(PAID_AMOUNT_STRING_MESSAGE, path, "SYN-740-FLOAT")
  end

  def test_fixture_loader_refuses_category_disagreeing_with_category_code
    expected_row = {
      "category" => "finalized_paid",
      "category_code" => "F2",
      "status_code" => "65",
      "paid_amount" => "10.00",
      "paid_date" => nil
    }
    path = write_claim_status_table(<<~YAML, "SYN-740-MISMATCH" => expected_row)
      SYN-740-MISMATCH:
        category: finalized_paid
        category_code: "F2"
        status_code: "65"
        paid_amount: "10.00"
        paid_date: null
    YAML

    assert_fixture_load_refusal(CATEGORY_DISAGREES_MESSAGE, path, "SYN-740-MISMATCH")
  end

  def test_fixture_loader_refuses_an_unknown_row_field
    expected_row = {
      "category" => "pending",
      "category_code" => "P1",
      "status_code" => "20",
      "paid_amount" => nil,
      "paid_date" => nil,
      "extra_field" => true
    }
    path = write_claim_status_table(<<~YAML, "SYN-740-UNKNOWN" => expected_row)
      SYN-740-UNKNOWN:
        category: pending
        category_code: "P1"
        status_code: "20"
        paid_amount: null
        paid_date: null
        extra_field: true
    YAML

    assert_fixture_load_refusal(UNKNOWN_FIELD_MESSAGE, path, "SYN-740-UNKNOWN")
  end

  def test_fixture_loader_refuses_a_non_string_category_code
    expected_row = {
      "category" => "pending",
      "category_code" => 12,
      "status_code" => "20",
      "paid_amount" => nil,
      "paid_date" => nil
    }
    path = write_claim_status_table(<<~YAML, "SYN-740-CODE-TYPE" => expected_row)
      SYN-740-CODE-TYPE:
        category: pending
        category_code: 12
        status_code: "20"
        paid_amount: null
        paid_date: null
    YAML

    assert_fixture_load_refusal(CATEGORY_CODE_STRING_MESSAGE, path, "SYN-740-CODE-TYPE")
  end

  def test_fixture_loader_refuses_an_impossible_calendar_paid_date
    expected_row = {
      "category" => "finalized_paid",
      "category_code" => "F1",
      "status_code" => "65",
      "paid_amount" => "10.00",
      "paid_date" => "2026-02-30"
    }
    path = write_claim_status_table(<<~YAML, "SYN-740-BAD-DATE" => expected_row)
      SYN-740-BAD-DATE:
        category: finalized_paid
        category_code: "F1"
        status_code: "65"
        paid_amount: "10.00"
        paid_date: "2026-02-30"
    YAML

    assert_fixture_load_refusal(INVALID_CALENDAR_DATE_MESSAGE, path, "SYN-740-BAD-DATE")
  end

  def test_fixture_loader_accepts_one_well_formed_row_and_answers_for_it
    expected_row = {
      "category" => "pending",
      "category_code" => "P1",
      "status_code" => "20",
      "paid_amount" => nil,
      "paid_date" => nil
    }
    path = write_claim_status_table(<<~YAML, "SYN-740-VALID" => expected_row)
      SYN-740-VALID:
        category: pending
        category_code: "P1"
        status_code: "20"
        paid_amount: null
        paid_date: null
    YAML

    client = Corvid::Rcm::FixtureClearinghouseClient.new(claim_statuses: path, clock: FIXED_CLOCK)
    status = client.check_claim_status("SYN-740-VALID")

    assert_equal "SYN-740-VALID", status.claim_identifier
    assert_equal :pending, status.category
    assert_equal "P1", status.category_code
    assert_equal "20", status.status_code
    assert_nil status.paid_amount
    assert_nil status.paid_date
    assert_equal FIXED_CLOCK.call, status.as_of
    assert status.pending?
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

  private

  def write_claim_status_table(yaml_body, expected_rows)
    path = File.join(@tmpdir, "claim_statuses_#{SecureRandom.hex(4)}.yml")
    File.write(path, yaml_body)
    loaded = YAML.safe_load(File.read(path))

    expected_rows.each do |identifier, expected|
      assert_equal expected, loaded.fetch(identifier)
    end

    path
  end

  def assert_fixture_load_refusal(expected_message, path, claim_identifier)
    error = assert_raises(ArgumentError) do
      Corvid::Rcm::FixtureClearinghouseClient.new(claim_statuses: path, clock: FIXED_CLOCK)
    end

    assert_equal expected_message, error.message
    refute_includes error.message, claim_identifier
  end
end
