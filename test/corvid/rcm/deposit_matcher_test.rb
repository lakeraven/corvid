# frozen_string_literal: true

require "bigdecimal"
require "minitest/autorun"
require "corvid/rcm"

# Failing spec for issue #750: match bank deposits to 835 remittances by trace
# and amount. Implementation lives in lib/corvid/rcm/deposit*.rb (not yet present).
class Corvid::Rcm::DepositMatcherTest < Minitest::Test
  FIXTURE_CLIENT = Corvid::Rcm::FixtureClearinghouseClient.new

  DEPOSIT_DATE = Date.new(2026, 9, 2)

  def fixture_remittance(scenario)
    FIXTURE_CLIENT.remittance(scenario)
  end

  def build_remittance(remittance_identifier:, payment_amount:, payment_method: "ACH", **rest)
    Corvid::Rcm::Remittance.new(
      remittance_identifier: remittance_identifier,
      payment_amount: payment_amount,
      payment_method: payment_method,
      claims: [],
      **rest
    )
  end

  def build_deposit(deposit_identifier:, trace_number:, amount:, deposited_on: DEPOSIT_DATE, payer_name: nil)
    Corvid::Rcm::Deposit.new(
      deposit_identifier: deposit_identifier,
      trace_number: trace_number,
      amount: amount,
      deposited_on: deposited_on,
      payer_name: payer_name
    )
  end

  def match(remittances:, deposits:)
    Corvid::Rcm::DepositMatcher.match(remittances: remittances, deposits: deposits)
  end

  # -- Corvid::Rcm::Deposit --------------------------------------------------

  def test_deposit_exposes_expected_members_and_default_payer_name
    deposit = build_deposit(
      deposit_identifier: "DEP-0001",
      trace_number: "TRC-0001",
      amount: BigDecimal("200.00")
    )

    assert_equal %i[deposit_identifier trace_number amount deposited_on payer_name], deposit.members
    assert_nil deposit.payer_name
    assert deposit.frozen?
  end

  def test_deposit_amount_accepts_bigdecimal_and_integer
    from_decimal = build_deposit(deposit_identifier: "DEP-D", trace_number: "T", amount: BigDecimal("10"))
    from_integer = build_deposit(deposit_identifier: "DEP-I", trace_number: "T", amount: 10)

    assert_equal BigDecimal("10"), from_decimal.amount
    assert_equal BigDecimal("10"), from_integer.amount
  end

  def test_deposit_amount_rejects_inexact_or_missing_money
    assert_argument_error { build_deposit(deposit_identifier: "DEP-F", trace_number: "T", amount: 10.0) }
    assert_argument_error { build_deposit(deposit_identifier: "DEP-S", trace_number: "T", amount: "10") }
    assert_argument_error { build_deposit(deposit_identifier: "DEP-N", trace_number: "T", amount: nil) }
  end

  def test_deposit_deposited_on_must_be_a_date
    assert_argument_error do
      build_deposit(deposit_identifier: "DEP-X", trace_number: "T", amount: 1, deposited_on: "2026-09-02")
    end
    assert_argument_error do
      build_deposit(deposit_identifier: "DEP-X", trace_number: "T", amount: 1, deposited_on: Time.utc(2026, 9, 2))
    end
    assert_argument_error do
      build_deposit(deposit_identifier: "DEP-X", trace_number: "T", amount: 1, deposited_on: nil)
    end
  end

  def test_deposit_identifier_must_be_a_non_blank_string
    assert_argument_error { build_deposit(deposit_identifier: "", trace_number: "T", amount: 1) }
    assert_argument_error { build_deposit(deposit_identifier: "   ", trace_number: "T", amount: 1) }
    assert_argument_error { build_deposit(deposit_identifier: nil, trace_number: "T", amount: 1) }
  end

  def test_deposit_trace_number_accepts_string_and_nil
    with_trace = build_deposit(deposit_identifier: "DEP-1", trace_number: "TRC-0001", amount: 1)
    without_trace = build_deposit(deposit_identifier: "DEP-2", trace_number: nil, amount: 1)

    assert_equal "TRC-0001", with_trace.trace_number
    assert_nil without_trace.trace_number
  end

  def test_deposit_trace_number_rejects_non_string_types
    assert_argument_error { build_deposit(deposit_identifier: "DEP-1", trace_number: 12_345, amount: 1) }
  end

  # -- inputs ----------------------------------------------------------------

  def test_match_requires_array_arguments
    remittance = build_remittance(remittance_identifier: "T", payment_amount: BigDecimal("1"))

    assert_argument_error { match(remittances: nil, deposits: []) }
    assert_argument_error { match(remittances: [], deposits: nil) }
    assert_argument_error { match(remittances: {}, deposits: []) }
    assert_argument_error { match(remittances: [], deposits: {}) }
    assert_argument_error { match(remittances: [ remittance ], deposits: [ {} ]) }
    assert_argument_error { match(remittances: [ Object.new ], deposits: []) }
  end

  def test_rejects_remittance_list_with_a_deposit_element
    deposit = build_deposit(deposit_identifier: "DEP-WRONG-LIST", trace_number: "T", amount: BigDecimal("1"))

    assert_argument_error { match(remittances: [ deposit ], deposits: []) }
  end

  def test_remittance_payment_amount_must_be_exact_bigdecimal
    assert_argument_error do
      match(remittances: [ build_remittance(remittance_identifier: "T", payment_amount: nil, payment_method: "ACH") ],
            deposits: [])
    end
    assert_argument_error do
      match(remittances: [ build_remittance(remittance_identifier: "T", payment_amount: 1.0, payment_method: "ACH") ],
            deposits: [])
    end
  end

  def test_empty_both_sides_returns_an_empty_frozen_result
    result = match(remittances: [], deposits: [])

    assert_kind_of Corvid::Rcm::DepositMatchResult, result
    assert result.frozen?
    assert_empty result.matched
    assert_empty result.unmatched_remittances
    assert_empty result.unmatched_deposits
    assert_empty result.amount_mismatches
    assert result.matched.frozen?
    assert result.unmatched_remittances.frozen?
    assert result.unmatched_deposits.frozen?
    assert result.amount_mismatches.frozen?
  end

  # -- acceptance (issue #750) -----------------------------------------------

  def test_acceptance_exact_match
    remittance = fixture_remittance("clean_full_pay")
    deposit = build_deposit(
      deposit_identifier: "DEP-ACCEPT-EXACT",
      trace_number: remittance.remittance_identifier,
      amount: remittance.payment_amount
    )

    result = match(remittances: [ remittance ], deposits: [ deposit ])

    assert_equal 1, result.matched.length
    assert_empty result.unmatched_remittances
    assert_empty result.unmatched_deposits
    assert_empty result.amount_mismatches
    pair = result.matched.first
    assert_kind_of Corvid::Rcm::DepositMatch, pair
    assert pair.frozen?
    assert_equal %i[remittance deposit], pair.members
    assert_same remittance, pair.remittance
    assert_same deposit, pair.deposit
  end

  def test_acceptance_amount_mismatch
    remittance = build_remittance(
      remittance_identifier: "TRC-0001",
      payment_amount: BigDecimal("200.00"),
      payment_method: "ACH"
    )
    deposit = build_deposit(
      deposit_identifier: "DEP-MISMATCH",
      trace_number: "TRC-0001",
      amount: BigDecimal("200.01")
    )

    result = match(remittances: [ remittance ], deposits: [ deposit ])

    assert_empty result.matched
    assert_empty result.unmatched_remittances
    assert_empty result.unmatched_deposits
    assert_equal 1, result.amount_mismatches.length
    mismatch = result.amount_mismatches.first
    assert_kind_of Corvid::Rcm::DepositAmountMismatch, mismatch
    assert mismatch.frozen?
    assert_equal %i[remittance deposit difference], mismatch.members
    assert_same remittance, mismatch.remittance
    assert_same deposit, mismatch.deposit
    assert_kind_of BigDecimal, mismatch.difference
    assert_equal BigDecimal("0.01"), mismatch.difference
  end

  def test_amount_mismatch_difference_is_negative_when_deposit_is_short
    remittance = build_remittance(
      remittance_identifier: "TRC-SHORT",
      payment_amount: BigDecimal("200.00"),
      payment_method: "ACH"
    )
    deposit = build_deposit(
      deposit_identifier: "DEP-SHORT",
      trace_number: "TRC-SHORT",
      amount: BigDecimal("150.25")
    )

    result = match(remittances: [ remittance ], deposits: [ deposit ])

    assert_equal 1, result.amount_mismatches.length
    mismatch = result.amount_mismatches.first
    assert_equal BigDecimal("-49.75"), mismatch.difference
  end

  def test_deposit_integer_amount_matches_bigdecimal_payment
    remittance = build_remittance(
      remittance_identifier: "TRC-INT-AMT",
      payment_amount: BigDecimal("75.00"),
      payment_method: "ACH"
    )
    deposit = build_deposit(
      deposit_identifier: "DEP-INT-AMT",
      trace_number: "TRC-INT-AMT",
      amount: 75
    )

    result = match(remittances: [ remittance ], deposits: [ deposit ])

    assert_equal 1, result.matched.length
    pair = result.matched.first
    assert_same remittance, pair.remittance
    assert_same deposit, pair.deposit
    assert_kind_of BigDecimal, deposit.amount
  end

  def test_acceptance_unmatched_remittance
    remittance = build_remittance(
      remittance_identifier: "TRC-ORPHAN-R",
      payment_amount: BigDecimal("50.00"),
      payment_method: "ACH"
    )

    result = match(remittances: [ remittance ], deposits: [])

    assert_empty result.matched
    assert_equal [ remittance ], result.unmatched_remittances
    assert_empty result.unmatched_deposits
    assert_empty result.amount_mismatches
  end

  def test_acceptance_unmatched_deposit
    deposit = build_deposit(
      deposit_identifier: "DEP-ORPHAN-D",
      trace_number: "TRC-ORPHAN-D",
      amount: BigDecimal("75.00")
    )

    result = match(remittances: [], deposits: [ deposit ])

    assert_empty result.matched
    assert_empty result.unmatched_remittances
    assert_equal [ deposit ], result.unmatched_deposits
    assert_empty result.amount_mismatches
  end

  def test_acceptance_zero_pay_remittance_excluded_via_denial_fixture
    remittance = fixture_remittance("denial_missing_information_co16")

    assert_equal "NON", remittance.payment_method
    assert remittance.payment_amount.zero?

    deposit = build_deposit(
      deposit_identifier: "DEP-SAME-TRACE-AS-DENIAL",
      trace_number: remittance.remittance_identifier,
      amount: BigDecimal("100.00")
    )

    result = match(remittances: [ remittance ], deposits: [ deposit ])

    assert_empty result.matched
    assert_empty result.unmatched_remittances
    assert_equal [ deposit ], result.unmatched_deposits
    assert_empty result.amount_mismatches
  end

  def test_acceptance_duplicate_trace_numbers
    first = build_remittance(remittance_identifier: "TRC-DUP", payment_amount: BigDecimal("10.00"))
    second = build_remittance(remittance_identifier: "TRC-DUP", payment_amount: BigDecimal("10.00"))
    deposit = build_deposit(deposit_identifier: "DEP-DUP", trace_number: "TRC-DUP", amount: BigDecimal("10.00"))

    result = match(remittances: [ first, second ], deposits: [ deposit ])

    assert_empty result.matched
    assert_equal [ first, second ], result.unmatched_remittances
    assert_equal [ deposit ], result.unmatched_deposits
    assert_empty result.amount_mismatches
  end

  # -- one-sided unmatched ---------------------------------------------------

  def test_unmatched_remittances_only_with_no_deposits
    a = build_remittance(remittance_identifier: "TRC-A", payment_amount: BigDecimal("1.00"))
    b = build_remittance(remittance_identifier: "TRC-B", payment_amount: BigDecimal("2.00"))

    result = match(remittances: [ a, b ], deposits: [])

    assert_equal [ a, b ], result.unmatched_remittances
    assert_empty result.unmatched_deposits
  end

  def test_unmatched_deposits_only_with_no_remittances
    x = build_deposit(deposit_identifier: "DEP-X", trace_number: "TRC-X", amount: BigDecimal("3.00"))
    y = build_deposit(deposit_identifier: "DEP-Y", trace_number: "TRC-Y", amount: BigDecimal("4.00"))

    result = match(remittances: [], deposits: [ x, y ])

    assert_equal [ x, y ], result.unmatched_deposits
    assert_empty result.unmatched_remittances
  end

  # -- trace normalisation ---------------------------------------------------

  def test_exact_match_strips_surrounding_whitespace_on_traces
    remittance = build_remittance(
      remittance_identifier: "  TRC-WS-R  \n",
      payment_amount: BigDecimal("200.00")
    )
    deposit = build_deposit(
      deposit_identifier: "DEP-WS",
      trace_number: "\tTRC-WS-R",
      amount: BigDecimal("200")
    )

    result = match(remittances: [ remittance ], deposits: [ deposit ])

    assert_equal 1, result.matched.length
  end

  def test_leading_zeros_are_significant_so_000123_does_not_match_123
    remittance = build_remittance(remittance_identifier: "000123", payment_amount: BigDecimal("1.00"))
    deposit = build_deposit(deposit_identifier: "DEP-LZ", trace_number: "123", amount: BigDecimal("1.00"))

    result = match(remittances: [ remittance ], deposits: [ deposit ])

    assert_equal [ remittance ], result.unmatched_remittances
    assert_equal [ deposit ], result.unmatched_deposits
    assert_empty result.matched
  end

  def test_trace_comparison_is_case_sensitive
    remittance = build_remittance(remittance_identifier: "trc-case", payment_amount: BigDecimal("1.00"))
    deposit = build_deposit(deposit_identifier: "DEP-CASE", trace_number: "TRC-CASE", amount: BigDecimal("1.00"))

    result = match(remittances: [ remittance ], deposits: [ deposit ])

    assert_equal [ remittance ], result.unmatched_remittances
    assert_equal [ deposit ], result.unmatched_deposits
  end

  def test_blank_trace_after_normalisation_is_unmatched_remittance
    remittance = build_remittance(remittance_identifier: "   \t\n", payment_amount: BigDecimal("5.00"))

    result = match(remittances: [ remittance ], deposits: [])

    assert_equal [ remittance ], result.unmatched_remittances
  end

  def test_blank_trace_after_normalisation_is_unmatched_deposit
    deposit = build_deposit(deposit_identifier: "DEP-BLANK-TRACE", trace_number: "  ", amount: BigDecimal("5.00"))

    result = match(remittances: [], deposits: [ deposit ])

    assert_equal [ deposit ], result.unmatched_deposits
  end

  # -- exclusion rules -------------------------------------------------------

  def test_non_payment_method_is_stripped_and_upcased_before_exclusion
    remittance = build_remittance(
      remittance_identifier: "TRC-NON",
      payment_amount: BigDecimal("25.00"),
      payment_method: " non "
    )
    deposit = build_deposit(deposit_identifier: "DEP-NON", trace_number: "TRC-NON", amount: BigDecimal("25.00"))

    result = match(remittances: [ remittance ], deposits: [ deposit ])

    assert_empty result.matched
    assert_empty result.unmatched_remittances
    assert_equal [ deposit ], result.unmatched_deposits
  end

  def test_zero_payment_amount_remittance_is_excluded_even_when_method_is_ach
    remittance = build_remittance(
      remittance_identifier: "TRC-ZERO",
      payment_amount: BigDecimal("0.00"),
      payment_method: "ACH"
    )
    deposit = build_deposit(deposit_identifier: "DEP-ZERO", trace_number: "TRC-ZERO", amount: BigDecimal("0.00"))

    result = match(remittances: [ remittance ], deposits: [ deposit ])

    assert_empty result.matched
    assert_empty result.unmatched_remittances
    assert_equal [ deposit ], result.unmatched_deposits
    assert_same deposit, result.unmatched_deposits.first
    assert_empty result.amount_mismatches
  end

  def test_excluded_remittance_does_not_block_deposit_with_same_trace
    excluded = fixture_remittance("denial_missing_information_co16")
    paying = build_remittance(
      remittance_identifier: excluded.remittance_identifier,
      payment_amount: BigDecimal("200.00"),
      payment_method: "ACH"
    )
    deposit = build_deposit(
      deposit_identifier: "DEP-BLOCK",
      trace_number: excluded.remittance_identifier,
      amount: BigDecimal("200.00")
    )

    result = match(remittances: [ excluded, paying ], deposits: [ deposit ])

    assert_equal 1, result.matched.length
    assert_same paying, result.matched.first.remittance
    assert_same deposit, result.matched.first.deposit
    assert_empty result.unmatched_remittances
    assert_empty result.unmatched_deposits
  end

  # -- amount exactness ------------------------------------------------------

  def test_bigdecimal_200_matches_bigdecimal_200_00
    remittance = build_remittance(remittance_identifier: "TRC-AMT", payment_amount: BigDecimal("200"))
    deposit = build_deposit(deposit_identifier: "DEP-AMT", trace_number: "TRC-AMT", amount: BigDecimal("200.00"))

    result = match(remittances: [ remittance ], deposits: [ deposit ])

    assert_equal 1, result.matched.length
  end

  def test_amount_mismatch_pair_never_appears_in_matched_or_unmatched_lists
    remittance = build_remittance(remittance_identifier: "TRC-MM", payment_amount: BigDecimal("90.00"))
    deposit = build_deposit(deposit_identifier: "DEP-MM", trace_number: "TRC-MM", amount: BigDecimal("90.01"))

    result = match(remittances: [ remittance ], deposits: [ deposit ])

    refute_includes result.matched.map(&:remittance), remittance
    refute_includes result.unmatched_remittances, remittance
    refute_includes result.unmatched_deposits, deposit
  end

  # -- duplicates ------------------------------------------------------------

  def test_duplicate_trace_on_two_remittances_and_one_deposit
    shared = "TRC-TWO-R"
    r1 = build_remittance(remittance_identifier: shared, payment_amount: BigDecimal("1.00"))
    r2 = build_remittance(remittance_identifier: shared, payment_amount: BigDecimal("1.00"))
    deposit = build_deposit(deposit_identifier: "DEP-1", trace_number: shared, amount: BigDecimal("1.00"))

    result = match(remittances: [ r1, r2 ], deposits: [ deposit ])

    assert_equal [ r1, r2 ], result.unmatched_remittances
    assert_equal [ deposit ], result.unmatched_deposits
    assert_empty result.matched
  end

  def test_duplicate_trace_on_one_remittance_and_two_deposits
    remittance = build_remittance(remittance_identifier: "TRC-TWO-D", payment_amount: BigDecimal("2.00"))
    d1 = build_deposit(deposit_identifier: "DEP-A", trace_number: "TRC-TWO-D", amount: BigDecimal("2.00"))
    d2 = build_deposit(deposit_identifier: "DEP-B", trace_number: "TRC-TWO-D", amount: BigDecimal("2.00"))

    result = match(remittances: [ remittance ], deposits: [ d1, d2 ])

    assert_equal [ remittance ], result.unmatched_remittances
    assert_equal [ d1, d2 ], result.unmatched_deposits
  end

  def test_duplicate_traces_that_differ_only_by_surrounding_whitespace
    r1 = build_remittance(remittance_identifier: "TRC-WS-DUP", payment_amount: BigDecimal("3.00"))
    r2 = build_remittance(remittance_identifier: "  TRC-WS-DUP  ", payment_amount: BigDecimal("3.00"))
    deposit = build_deposit(deposit_identifier: "DEP-WS-DUP", trace_number: "TRC-WS-DUP", amount: BigDecimal("3.00"))

    result = match(remittances: [ r1, r2 ], deposits: [ deposit ])

    assert_equal [ r1, r2 ], result.unmatched_remittances
    assert_equal [ deposit ], result.unmatched_deposits
  end

  def test_other_traces_still_match_when_one_trace_is_duplicated
    dup_a = build_remittance(remittance_identifier: "TRC-DUP-GROUP", payment_amount: BigDecimal("1.00"))
    dup_b = build_remittance(remittance_identifier: "TRC-DUP-GROUP", payment_amount: BigDecimal("1.00"))
    solo_r = build_remittance(remittance_identifier: "TRC-SOLO-OK", payment_amount: BigDecimal("10.00"))
    solo_d = build_deposit(deposit_identifier: "DEP-SOLO", trace_number: "TRC-SOLO-OK", amount: BigDecimal("10.00"))
    dup_d = build_deposit(deposit_identifier: "DEP-DUP-G", trace_number: "TRC-DUP-GROUP", amount: BigDecimal("1.00"))

    result = match(remittances: [ dup_a, dup_b, solo_r ], deposits: [ dup_d, solo_d ])

    assert_equal 1, result.matched.length
    assert_same solo_r, result.matched.first.remittance
    assert_same solo_d, result.matched.first.deposit
    assert_equal [ dup_a, dup_b ], result.unmatched_remittances
    assert_equal [ dup_d ], result.unmatched_deposits
  end

  # -- fixture-backed matching -----------------------------------------------

  def test_partial_pay_fixture_matches_deposit_by_trace_and_amount
    remittance = fixture_remittance("partial_pay_patient_responsibility")
    deposit = build_deposit(
      deposit_identifier: "DEP-PARTIAL",
      trace_number: remittance.remittance_identifier,
      amount: remittance.payment_amount
    )

    result = match(remittances: [ remittance ], deposits: [ deposit ])

    assert_equal 1, result.matched.length
    assert_equal BigDecimal("90.00"), remittance.payment_amount
  end

  # -- ordering --------------------------------------------------------------

  def test_matched_and_mismatches_follow_remittance_input_order
    r1 = build_remittance(remittance_identifier: "TRC-ORD-1", payment_amount: BigDecimal("1.00"))
    r2 = build_remittance(remittance_identifier: "TRC-ORD-2", payment_amount: BigDecimal("2.00"))
    d1 = build_deposit(deposit_identifier: "DEP-ORD-1", trace_number: "TRC-ORD-1", amount: BigDecimal("1.00"))
    d2 = build_deposit(deposit_identifier: "DEP-ORD-2", trace_number: "TRC-ORD-2", amount: BigDecimal("9.00"))

    result = match(remittances: [ r1, r2 ], deposits: [ d1, d2 ])

    assert_same r1, result.matched.first.remittance
    assert_same r2, result.amount_mismatches.first.remittance
  end

  def test_unmatched_lists_follow_their_own_input_order
    r2 = build_remittance(remittance_identifier: "TRC-U-2", payment_amount: BigDecimal("1.00"))
    r1 = build_remittance(remittance_identifier: "TRC-U-1", payment_amount: BigDecimal("1.00"))
    d2 = build_deposit(deposit_identifier: "DEP-U-2", trace_number: "TRC-UD-2", amount: BigDecimal("1.00"))
    d1 = build_deposit(deposit_identifier: "DEP-U-1", trace_number: "TRC-UD-1", amount: BigDecimal("1.00"))

    result = match(remittances: [ r2, r1 ], deposits: [ d2, d1 ])

    assert_equal [ r2, r1 ], result.unmatched_remittances
    assert_equal [ d2, d1 ], result.unmatched_deposits
  end

  # -- conservation ----------------------------------------------------------

  def test_conservation_mixed_scenario_partitions_every_non_excluded_item
    excluded = fixture_remittance("denial_missing_information_co16")
    matched_r = fixture_remittance("clean_full_pay")
    matched_d = build_deposit(
      deposit_identifier: "DEP-MIX-MATCH",
      trace_number: matched_r.remittance_identifier,
      amount: matched_r.payment_amount
    )
    mismatch_r = build_remittance(
      remittance_identifier: "TRC-MIX-MM",
      payment_amount: BigDecimal("90.00"),
      payment_method: "ACH"
    )
    mismatch_d = build_deposit(
      deposit_identifier: "DEP-MIX-MM",
      trace_number: "TRC-MIX-MM",
      amount: BigDecimal("90.01")
    )
    unmatched_r = build_remittance(remittance_identifier: "TRC-MIX-UR", payment_amount: BigDecimal("11.00"))
    unmatched_d = build_deposit(deposit_identifier: "DEP-MIX-UD", trace_number: "TRC-MIX-UD", amount: BigDecimal("12.00"))
    dup_r1 = build_remittance(remittance_identifier: "TRC-MIX-DUP", payment_amount: BigDecimal("1.00"))
    dup_r2 = build_remittance(remittance_identifier: "TRC-MIX-DUP", payment_amount: BigDecimal("1.00"))
    dup_d = build_deposit(deposit_identifier: "DEP-MIX-DUP", trace_number: "TRC-MIX-DUP", amount: BigDecimal("1.00"))

    remittances = [ excluded, matched_r, mismatch_r, unmatched_r, dup_r1, dup_r2 ]
    deposits = [ matched_d, mismatch_d, unmatched_d, dup_d ]

    result = match(remittances: remittances, deposits: deposits)

    refute_includes all_remittance_slots(result), excluded

    assert_single_partition(remittances - [ excluded ], all_remittance_slots(result))
    assert_single_partition(deposits, all_deposit_slots(result))
  end

  private

  def assert_argument_error(&block)
    begin
      block.call
    rescue ArgumentError
      return
    end
    flunk "expected ArgumentError"
  end

  def all_remittance_slots(result)
    result.matched.map(&:remittance) +
      result.amount_mismatches.map(&:remittance) +
      result.unmatched_remittances
  end

  def all_deposit_slots(result)
    result.matched.map(&:deposit) +
      result.amount_mismatches.map(&:deposit) +
      result.unmatched_deposits
  end

  def assert_single_partition(expected_items, actual_slots)
    assert_equal expected_items.length, actual_slots.length
    expected_items.each do |item|
      occurrences = actual_slots.count { |slot| slot.equal?(item) }
      assert_equal 1, occurrences, "expected #{item.inspect} in exactly one result list"
    end
  end
end
