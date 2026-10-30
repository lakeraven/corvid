# frozen_string_literal: true

require_relative "acknowledgment"

module Corvid
  module Rcm
    # Pre-submission front-end edits from the clearinghouse.
    #
    # This is a REJECTION, never a DENIAL. Nothing was adjudicated, there is
    # no payment decision to appeal, and the only response to a failure is
    # fix-and-resubmit. See acknowledgment.rb. Corvid's own scrub runs first;
    # this check runs last, before the claim is submitted.
    #
    # `valid` is exactly true or exactly false, and it is true only when
    # `edits` is empty. Every edit is an `AcknowledgmentEdit`. `raw_reference`
    # is the transport's own handle for the response, when it has one; callers
    # that have no transport leave it nil.
    #
    # A failure answers as a rejected `Acknowledgment` with transaction_set
    # "validation", so disposition and work queue follow a rejected 277CA.
    # A passing validation is not an acknowledgment: there is nothing to route.
    ClaimValidation = Data.define(
      :claim_identifier,
      :valid,
      :edits,
      :raw_reference
    ) do
      def initialize(claim_identifier:, valid:, edits:, raw_reference: nil)
        checked_valid = strict_boolean(valid)
        checked_edits = freeze_edits(edits)
        ensure_edits_match_validity(checked_valid, checked_edits)
        super(
          claim_identifier: claim_identifier,
          valid: checked_valid,
          edits: checked_edits,
          raw_reference: raw_reference
        )
      end

      def valid?
        valid
      end

      # Rejected acknowledgment for a failed validation. The trace number is
      # "VAL-" plus the claim identifier. `received_at` is recorded only when
      # the caller has one.
      def to_acknowledgment(received_at: nil)
        raise ArgumentError, "a passing validation is not an acknowledgment" if valid?

        Acknowledgment.new(
          claim_identifier: claim_identifier,
          trace_number: "VAL-#{claim_identifier}",
          outcome: :rejected,
          transaction_set: "validation",
          received_at: received_at,
          edits: edits
        )
      end

      private

      def strict_boolean(value)
        return value if value.equal?(true) || value.equal?(false)

        raise ArgumentError, "valid must be true or false"
      end

      def freeze_edits(edits)
        unless edits.is_a?(Array) && edits.all?(AcknowledgmentEdit)
          raise ArgumentError, "edits must be an array of AcknowledgmentEdit"
        end

        edits.dup.freeze
      end

      def ensure_edits_match_validity(valid, edits)
        return if valid == edits.empty?

        raise ArgumentError, "a passing validation cannot carry edits" if valid

        raise ArgumentError, "a failing validation must include an edit"
      end
    end
  end
end
