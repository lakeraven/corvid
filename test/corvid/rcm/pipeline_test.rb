# frozen_string_literal: true

require "minitest/autorun"
require "corvid/rcm"
require_relative "claim_factory"

# The Phase 0 pieces working together: scrub, submit, acknowledge, post.
# Nothing here touches a database or a network.
class Corvid::Rcm::PipelineTest < Minitest::Test
  Factory = Corvid::Rcm::ClaimFactory

  def setup
    @scrubber = Corvid::Rcm::Scrubber.new
    @clearinghouse = Corvid::Rcm::FixtureClearinghouseClient.new
    @classifier = Corvid::Rcm::RemittanceClassifier.new
  end

  def test_a_blocked_claim_never_reaches_the_clearinghouse
    claim = Factory.claim_with_line(encounter_modality: :telehealth_patient_home,
                                    place_of_service: "11", modifiers: [])
    result = @scrubber.scrub(claim, as_of: Factory::TODAY)

    refute result.submittable?
    @clearinghouse.submit_claim(claim) if result.submittable?

    assert_empty @clearinghouse.submitted, "a blocked claim must not be transmitted"
  end

  def test_a_clean_claim_goes_out_and_comes_back_acknowledged
    claim = Factory.claim
    result = @scrubber.scrub(claim, as_of: Factory::TODAY)
    assert result.submittable?

    ack = @clearinghouse.submit_claim(claim)

    assert ack.accepted?
    assert_equal [ claim ], @clearinghouse.submitted
  end

  def test_a_warned_claim_still_goes_out
    coverage = Factory.coverage(timely_filing_days: 90)
    claim = Factory.claim(coverage: coverage)
    result = @scrubber.scrub(claim, as_of: Date.new(2026, 10, 15))

    refute result.clean?
    assert result.submittable?
    assert @clearinghouse.submit_claim(claim).accepted?
  end

  def test_the_full_posting_pass_splits_machine_work_from_human_work
    routings = @clearinghouse.fetch_remittances
                             .flat_map { |rem| @classifier.classify_remittance(rem) }

    postable, human = routings.partition(&:auto_postable?)

    assert_equal %w[CLM-1001 CLM-1002], postable.map(&:claim_identifier).sort
    assert_equal 7, human.length
    assert_includes human.map(&:work_queue), :human_review

    closeable = routings.select(&:auto_closeable?)
    assert_equal [ "CLM-1001" ], closeable.map(&:claim_identifier),
                 "only the clean full payment is actually finished"
  end

  def test_a_rejection_and_a_denial_land_in_different_places
    rejection = @clearinghouse.submit_claim(Factory.claim(identifier: "CLM-RJ-0001"))
    denial = @classifier.classify(
      @clearinghouse.remittance("denial_medical_necessity_co50").claims.first
    )

    assert_equal :claim_rework, rejection.work_queue
    assert_equal :fix_and_resubmit, rejection.disposition
    assert_equal :medical_necessity_appeal, denial.work_queue
    assert_equal :denied, denial.outcome
    refute_equal rejection.work_queue, denial.work_queue
  end
end
