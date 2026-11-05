# frozen_string_literal: true

require "minitest/autorun"
require "corvid"
require "corvid/rcm"

class Corvid::Rcm::AcknowledgmentTest < Minitest::Test
  def test_acknowledgment_without_raw_reference_defaults_to_nil
    ack = Corvid::Rcm::Acknowledgment.new(
      claim_identifier: "CLM-1",
      trace_number: "ACK-1",
      outcome: :accepted
    )

    assert_nil ack.raw_reference
  end

  def test_acknowledgment_round_trips_raw_reference
    ack = Corvid::Rcm::Acknowledgment.new(
      claim_identifier: "CLM-1",
      trace_number: "ACK-1",
      outcome: :accepted,
      raw_reference: "ref-1"
    )

    assert_equal "ref-1", ack.raw_reference
  end

  def test_existing_keyword_callers_still_construct_acknowledgments
    ack = Corvid::Rcm::Acknowledgment.new(
      claim_identifier: "CLM-2001",
      trace_number: "ACK-CLM-2001",
      outcome: :accepted,
      transaction_set: "277CA",
      received_at: Time.utc(2026, 9, 1, 12, 0, 0),
      edits: []
    )

    assert ack.accepted?
    assert_nil ack.raw_reference
  end

  def test_acknowledgment_edits_array_is_frozen
    edit = Corvid::Rcm::AcknowledgmentEdit.new(code: "A7:562", description: "missing NPI")
    ack = Corvid::Rcm::Acknowledgment.new(
      claim_identifier: "CLM-1",
      trace_number: "ACK-1",
      outcome: :rejected,
      edits: [ edit ]
    )

    assert ack.edits.frozen?
    assert_raises(FrozenError) { ack.edits << edit }
  end

  def test_acknowledgment_edits_do_not_alias_the_callers_array
    edits = [
      Corvid::Rcm::AcknowledgmentEdit.new(code: "A7:562", description: "missing NPI")
    ]
    ack = Corvid::Rcm::Acknowledgment.new(
      claim_identifier: "CLM-1",
      trace_number: "ACK-1",
      outcome: :rejected,
      edits: edits
    )

    edits.clear

    refute_empty ack.edits
    assert_equal 1, ack.edits.length
  end
end
