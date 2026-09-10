# frozen_string_literal: true

require "minitest/autorun"
require "corvid/rcm"

# Covers the CARC/RARC table as data, the routing decision it drives, and the
# two invariants that live in code: unmapped codes go to a human and are never
# auto-closed, and denials are never auto-closed.
class Corvid::Rcm::RemittanceClassifierTest < Minitest::Test
  def setup
    @client = Corvid::Rcm::FixtureClearinghouseClient.new
    @classifier = Corvid::Rcm::RemittanceClassifier.new
    @codes = Corvid::Rcm::AdjustmentReasonCodes.default
  end

  def route(scenario)
    @classifier.classify(@client.remittance(scenario).claims.first)
  end

  # -- the mapping table -----------------------------------------------------

  def test_every_mapped_code_answers_all_three_questions
    @codes.mapped_codes.each do |code|
      classification = @codes.classify(code)

      refute_empty classification.reason.to_s, "#{code} has no reason"
      refute_empty classification.action.to_s, "#{code} has no next action"
      refute_nil classification.work_queue, "#{code} has no work queue"
    end
  end

  def test_lookup_is_case_and_whitespace_insensitive
    assert @codes.classify(" co-45 ").mapped?
  end

  def test_rarc_remark_codes_resolve_to_readable_text
    assert_match(/referring provider/, @codes.remark("N286"))
    assert_nil @codes.remark("N999")
  end

  # -- clean and partial payment ---------------------------------------------

  def test_a_clean_full_payment_closes_itself
    routing = route("clean_full_pay")

    assert_equal :paid_in_full, routing.outcome
    assert routing.auto_postable?
    assert routing.auto_closeable?
    assert_nil routing.work_queue
    assert_empty routing.unmapped_codes
  end

  def test_a_contractual_adjustment_with_a_patient_split_routes_to_patient_billing
    routing = route("partial_pay_patient_responsibility")

    assert_equal :paid_with_patient_responsibility, routing.outcome
    assert_equal :patient_billing, routing.work_queue
    assert_equal BigDecimal("50.00"), routing.contractual_amount
    assert_equal BigDecimal("30.00"), routing.patient_responsibility[:deductible]
    assert_equal BigDecimal("20.00"), routing.patient_responsibility[:coinsurance]
    assert_equal BigDecimal("10.00"), routing.patient_responsibility[:copay]
    assert_equal BigDecimal(0), routing.patient_responsibility[:other]
  end

  def test_a_patient_balance_posts_automatically_but_does_not_close_the_claim
    routing = route("partial_pay_patient_responsibility")

    assert routing.auto_postable?, "a routine payment with a patient split should post itself"
    refute routing.auto_closeable?, "somebody still owes money — the claim is not finished"
  end

  def test_the_patient_responsibility_split_reconciles_to_the_claim_total
    claim = @client.remittance("partial_pay_patient_responsibility").claims.first
    split = claim.patient_responsibility_breakdown

    assert_equal claim.patient_responsibility_amount, split.values.sum
  end

  # -- denials ---------------------------------------------------------------

  def test_each_denial_scenario_routes_to_its_own_queue
    {
      "denial_missing_information_co16" => :missing_information,
      "denial_duplicate_co18" => :duplicate_review,
      "denial_timely_filing_co29" => :timely_filing_appeal,
      "denial_medical_necessity_co50" => :medical_necessity_appeal,
      "denial_authorization_required_co197" => :authorization
    }.each do |scenario, queue|
      routing = route(scenario)

      assert_equal :denied, routing.outcome, "#{scenario} should be a denial"
      assert_equal queue, routing.work_queue, "#{scenario} routed to the wrong queue"
    end
  end

  def test_no_denial_is_ever_auto_posted_or_auto_closed
    %w[
      denial_missing_information_co16 denial_duplicate_co18 denial_timely_filing_co29
      denial_medical_necessity_co50 denial_authorization_required_co197
    ].each do |scenario|
      refute route(scenario).auto_postable?, "#{scenario} must not auto-post"
      refute route(scenario).auto_closeable?, "#{scenario} must not auto-close"
    end
  end

  def test_a_denial_carries_a_next_action_specific_enough_to_work_from
    routing = route("denial_duplicate_co18")

    assert_match(/Find the original claim/, routing.actions.first)
  end

  def test_a_bundled_line_alongside_a_paid_line_is_not_a_claim_level_denial
    routing = route("denial_bundled_co97")

    refute_equal :denied, routing.outcome
    assert_equal :auto_post, routing.work_queue
    refute routing.auto_closeable?, "a bundling adjustment needs a coding review before it closes"
  end

  def test_denial_remark_codes_are_resolved_to_text
    routing = route("denial_missing_information_co16")

    assert_equal({ "N286" => @codes.remark("N286") }, routing.remarks)
  end

  # -- the unmapped-code invariant -------------------------------------------

  def test_an_unmapped_code_is_classified_rather_than_guessed_at
    classification = @codes.classify("CO-234")

    refute classification.mapped?
    assert classification.unmapped?
    assert_equal :human_review, classification.work_queue
    assert_match(/will not guess/, classification.action)
  end

  def test_an_unmapped_code_routes_to_human_review
    routing = route("denial_unmapped_reason_code")

    assert_equal :needs_human_review, routing.outcome
    assert routing.needs_human_review?
    assert_equal :human_review, routing.work_queue
    assert_equal [ "CO-234" ], routing.unmapped_codes
  end

  def test_an_unmapped_code_can_never_be_auto_posted_or_auto_closed
    refute route("denial_unmapped_reason_code").auto_postable?
    refute route("denial_unmapped_reason_code").auto_closeable?
    refute @codes.classify("CO-234").auto_closeable?
  end

  def test_an_unmapped_code_outranks_everything_else_on_the_claim
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-MIXED",
      status_code: Corvid::Rcm::CLAIM_STATUS_PROCESSED_PRIMARY,
      billed_amount: BigDecimal("200.00"),
      paid_amount: BigDecimal("150.00"),
      adjustments: [
        Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("40.00")),
        Corvid::Rcm::Adjustment.new(group_code: "OA", reason_code: "999", amount: BigDecimal("10.00"))
      ]
    )
    routing = @classifier.classify(claim)

    assert_equal :needs_human_review, routing.outcome
    refute routing.auto_closeable?
    assert_equal [ "OA-999" ], routing.unmapped_codes
  end

  def test_classification_never_returns_nil_for_an_unknown_code
    refute_nil @codes.classify("ZZ-0")
    refute_nil Corvid::Rcm::AdjustmentReasonCodes.classify("ZZ-0")
  end

  # -- reversals -------------------------------------------------------------

  def test_a_reversal_is_never_a_quiet_auto_post
    claim = Corvid::Rcm::RemittanceClaim.new(
      claim_identifier: "CLM-REV",
      status_code: Corvid::Rcm::CLAIM_STATUS_REVERSAL,
      billed_amount: BigDecimal("200.00"),
      paid_amount: BigDecimal("-200.00"),
      adjustments: [ Corvid::Rcm::Adjustment.new(group_code: "CO", reason_code: "45", amount: BigDecimal("0")) ]
    )
    routing = @classifier.classify(claim)

    assert_equal :reversal, routing.outcome
    assert_equal :reversal_review, routing.work_queue
    refute routing.auto_closeable?
  end

  # -- whole remittances -----------------------------------------------------

  def test_a_whole_remittance_classifies_every_claim_on_it
    remittance = @client.remittance("denial_bundled_co97")

    assert_equal remittance.claims.length, @classifier.classify_remittance(remittance).length
  end

  def test_every_fixture_scenario_produces_a_routing_decision
    @client.fetch_remittances.each do |remittance|
      @classifier.classify_remittance(remittance).each do |routing|
        refute_nil routing.outcome
        refute_empty routing.claim_identifier
      end
    end
  end
end
