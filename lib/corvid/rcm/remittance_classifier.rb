# frozen_string_literal: true

require "bigdecimal"

require_relative "adjustment_reason_codes"
require_relative "remittance"

module Corvid
  module Rcm
    # The routing decision for one adjudicated claim: what happened to the
    # money, which queue the work lands in, and how much of it a machine may
    # finish on its own.
    #
    # `auto_postable` and `auto_closeable` are different questions and both
    # matter. A claim that pays with a patient balance is fully auto-POSTABLE —
    # the payment and the contractual write-off go straight in — but it is not
    # auto-CLOSEABLE, because somebody is still owed money. Collapsing the two
    # either strands routine payments in a human queue or quietly closes claims
    # with an open patient balance.
    RemittanceRouting = Data.define(
      :claim_identifier,
      :outcome,
      :work_queue,
      :auto_postable,
      :auto_closeable,
      :paid_amount,
      :contractual_amount,
      :patient_responsibility,
      :classifications,
      :unmapped_codes,
      :remarks
    ) do
      # The money can be posted without a human touching it.
      def auto_postable?
        auto_postable
      end

      # Nothing further is owed by anyone; the claim is finished.
      def auto_closeable?
        auto_closeable
      end

      def needs_human_review?
        outcome == :needs_human_review
      end

      def denied?
        outcome == :denied
      end

      # Every distinct next action a human would need to take, in the order the
      # adjustments appeared. This is what a work queue renders.
      def actions
        classifications.map(&:action).uniq
      end
    end

    # Turns an adjudicated claim from an 835 into a routing decision, using the
    # CARC/RARC table as data.
    #
    # Two invariants live here in code rather than in the data file, because
    # the data file is edited by people and these must not be forgettable:
    #
    #   1. An UNMAPPED reason code always routes to human review and is never
    #      auto-closeable, no matter what else is on the claim.
    #   2. A DENIAL is never auto-closeable. Adjudicated refusals get appealed
    #      or written off by a person who chose to.
    class RemittanceClassifier
      def initialize(reason_codes: AdjustmentReasonCodes.default)
        @reason_codes = reason_codes
      end

      attr_reader :reason_codes

      def classify(remittance_claim)
        classifications = remittance_claim.all_adjustments.map { |adj| @reason_codes.classify(adj.code) }
        unmapped = classifications.select(&:unmapped?)
        breakdown = remittance_claim.patient_responsibility_breakdown

        outcome, queue, auto_postable, auto_closeable =
          decide(remittance_claim, classifications, unmapped)

        RemittanceRouting.new(
          claim_identifier: remittance_claim.claim_identifier,
          outcome: outcome,
          work_queue: queue,
          auto_postable: auto_postable,
          auto_closeable: auto_closeable,
          paid_amount: remittance_claim.paid_amount,
          contractual_amount: remittance_claim.contractual_amount,
          patient_responsibility: breakdown,
          classifications: classifications,
          unmapped_codes: unmapped.map(&:code),
          remarks: remittance_claim.all_remark_codes.map { |code| [ code, @reason_codes.remark(code) ] }.to_h
        )
      end

      def classify_remittance(remittance)
        Array(remittance.claims).map { |clm| classify(clm) }
      end

      private

      # Returns [outcome, work_queue, auto_postable, auto_closeable].
      def decide(claim, classifications, unmapped)
        # Invariant 1 — an unmapped code outranks everything else on the claim.
        if unmapped.any?
          return [ :needs_human_review, AdjustmentReasonCodes::HUMAN_REVIEW_QUEUE, false, false ]
        end

        # A reversal takes money back; it is never a quiet auto-post.
        return [ :reversal, :reversal_review, false, false ] if claim.reversal?

        # Invariant 2 — denials are adjudicated refusals; a person decides.
        if claim.denied?
          denial = classifications.find(&:denial?)
          return [ :denied, denial&.work_queue || AdjustmentReasonCodes::HUMAN_REVIEW_QUEUE, false, false ]
        end

        return [ :paid_in_full, nil, true, true ] if classifications.empty?

        postable = classifications.all?(&:auto_closeable?)
        if classifications.any?(&:patient_responsibility?)
          # Postable, but the patient still owes something — not closed.
          [ :paid_with_patient_responsibility, :patient_billing, postable, false ]
        else
          [ :paid_with_adjustments, :auto_post, postable, postable ]
        end
      end
    end
  end
end
