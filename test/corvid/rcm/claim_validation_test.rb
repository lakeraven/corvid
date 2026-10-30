# frozen_string_literal: true

require "minitest/autorun"
require "corvid/rcm"
require_relative "claim_factory"

class Corvid::Rcm::ClaimValidationTest < Minitest::Test
  Factory = Corvid::Rcm::ClaimFactory
  Edit = Corvid::Rcm::AcknowledgmentEdit
  Validation = Corvid::Rcm::ClaimValidation
  FIXED_RECEIVED_AT = Time.utc(2026, 9, 1, 12, 0, 0)

  def sample_edit
    Edit.new(code: "A3:21", description: "sample edit", element: "HI", level: "claim")
  end

  def failing_validation(claim_identifier: "CLM-X", edits: nil)
    Validation.new(
      claim_identifier: claim_identifier,
      valid: false,
      edits: edits || [ sample_edit ]
    )
  end

  def passing_validation(claim_identifier: "CLM-2001")
    Validation.new(claim_identifier: claim_identifier, valid: true, edits: [])
  end

  # -- shape -----------------------------------------------------------------

  def test_it_is_a_data_object_with_the_expected_members
    validation = failing_validation

    assert_equal "CLM-X", validation.claim_identifier
    assert_equal false, validation.valid
    assert_equal 1, validation.edits.length
    assert_nil validation.raw_reference
  end

  def test_raw_reference_defaults_to_nil_when_omitted
    validation = Validation.new(claim_identifier: "CLM-1", valid: true, edits: [])

    assert_nil validation.raw_reference
  end

  def test_raw_reference_round_trips_for_passing_and_failing_validations
    edit = sample_edit

    failing = Validation.new(
      claim_identifier: "CLM-1",
      valid: false,
      edits: [ edit ],
      raw_reference: "txn-12345"
    )
    passing = Validation.new(claim_identifier: "CLM-1", valid: true, edits: [], raw_reference: "txn-12345")

    assert_equal "txn-12345", failing.raw_reference
    assert_equal "txn-12345", passing.raw_reference
  end

  def test_claim_identifier_must_be_non_blank
    pin = "CLM-PIN-738"

    [ nil, "", "  " ].each do |bad_identifier|
      error = assert_raises(ArgumentError) do
        Validation.new(claim_identifier: bad_identifier, valid: true, edits: [])
      end

      refute_includes error.message, pin
      refute_includes error.message, bad_identifier if bad_identifier.is_a?(String) && !bad_identifier.strip.empty?
    end
  end

  def test_a_failing_validation_rejects_edits_with_blank_code_or_description
    pin = "CLM-PIN-738"
    secret_code = "SYN-EDIT-CODE"
    secret_description = "Synthetic edit description for validation tests."

    bad_edits = [
      Edit.new(code: nil, description: secret_description, level: "claim"),
      Edit.new(code: secret_code, description: "", level: "claim")
    ]

    bad_edits.each do |bad_edit|
      error = assert_raises(ArgumentError) do
        Validation.new(claim_identifier: pin, valid: false, edits: [ bad_edit ])
      end

      refute_includes error.message, pin
      refute_includes error.message, secret_code
      refute_includes error.message, secret_description
    end
  end

  def test_edits_is_a_frozen_copy_of_the_caller_array
    edit = sample_edit
    caller_edits = [ edit ]
    validation = failing_validation(edits: caller_edits)

    assert_predicate validation.edits, :frozen?
    caller_edits << Edit.new(code: "X", description: "extra", level: "claim")

    assert_equal 1, validation.edits.length
    assert_equal [ edit ], validation.edits
  end

  def test_valid_must_be_exactly_true_or_false
    [ nil, "true", 1 ].each do |bad_valid|
      assert_raises(ArgumentError) do
        Validation.new(claim_identifier: "CLM-1", valid: bad_valid, edits: [])
      end
    end
  end

  def test_a_passing_validation_cannot_carry_edits
    assert_raises(ArgumentError) do
      Validation.new(claim_identifier: "CLM-1", valid: true, edits: [ sample_edit ])
    end
  end

  def test_a_failing_validation_must_explain_why
    assert_raises(ArgumentError) do
      Validation.new(claim_identifier: "CLM-1", valid: false, edits: [])
    end
  end

  def test_every_edit_must_be_an_acknowledgment_edit
    [ { code: "A1", description: "hash" }, "string edit" ].each do |bad_edit|
      assert_raises(ArgumentError) do
        Validation.new(claim_identifier: "CLM-1", valid: false, edits: [ bad_edit ])
      end
    end
  end

  def test_valid_returns_the_boolean_and_does_not_speak_denial_vocabulary
    assert passing_validation.valid?
    refute failing_validation.valid?

    refute_respond_to passing_validation, :denied?
    refute_respond_to passing_validation, :rejected?
  end

  # -- to_acknowledgment (failure only) --------------------------------------

  def test_a_failed_validation_becomes_a_rejected_validation_acknowledgment
    edit = sample_edit
    validation = failing_validation(claim_identifier: "CLM-2001", edits: [ edit ])
    ack = validation.to_acknowledgment

    assert ack.rejected?
    refute ack.accepted?
    assert_equal "validation", ack.transaction_set
    assert_equal [ edit ], ack.edits
    assert_equal validation.claim_identifier, ack.claim_identifier
    assert_equal :fix_and_resubmit, ack.disposition
    assert_equal :claim_rework, ack.work_queue
    refute_respond_to ack, :denied?
    refute_respond_to ack, :adjudicated?
  end

  def test_to_acknowledgment_uses_a_validation_trace_number_and_passes_received_at
    validation = failing_validation(claim_identifier: "CLM-VAL-1")
    ack = validation.to_acknowledgment(received_at: FIXED_RECEIVED_AT)

    assert_equal "VAL-CLM-VAL-1", ack.trace_number
    assert_equal FIXED_RECEIVED_AT, ack.received_at

    assert_nil failing_validation.to_acknowledgment.received_at
  end

  def test_a_passing_validation_is_not_an_acknowledgment
    assert_raises(ArgumentError) { passing_validation.to_acknowledgment }
  end

  # -- clearinghouse seam ----------------------------------------------------

  def test_the_base_clearinghouse_client_does_not_validate_yet
    claim = Factory.claim
    bare = Corvid::Rcm::ClearinghouseClient.new

    error = assert_raises(NotImplementedError) { bare.validate_claim(claim) }

    refute_includes error.message, claim.patient_identifier
  end
end
