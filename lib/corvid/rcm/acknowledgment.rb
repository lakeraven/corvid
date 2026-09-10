# frozen_string_literal: true

module Corvid
  module Rcm
    # A REJECTION is not a DENIAL. Phase 0 keeps the two vocabularies in
    # separate files so nothing can quietly blur them:
    #
    #   REJECTION (this file) — the claim was refused at the front door by the
    #     clearinghouse or the payer's intake edits (999 syntax acknowledgment,
    #     277CA claim acknowledgment). It was NEVER ADJUDICATED. There is no
    #     payment decision to appeal. The only correct response is
    #     fix-and-resubmit, and the claim is still "unbilled" for aging.
    #
    #   DENIAL (see remittance.rb) — the payer adjudicated the claim and
    #     refused payment on the 835. It carries CARC/RARC codes, it is a
    #     payment decision, and the response is appeal or write-off.
    #
    # Treating a rejection as a denial is the classic way a book of business
    # silently ages out past timely filing: the claim is sitting in an appeals
    # queue that has nothing to appeal, while the filing clock runs.

    # One intake edit. On a 999 this is the IK3/IK4 segment pair; on a 277CA it
    # is the STC status composite. Both collapse to the same shape: a code, a
    # human-readable description, and the element at fault.
    AcknowledgmentEdit = Data.define(:code, :description, :element, :level) do
      def initialize(code:, description:, element: nil, level: "claim")
        super
      end

      def to_s
        element ? "#{code}: #{description} (#{element})" : "#{code}: #{description}"
      end
    end

    ACKNOWLEDGMENT_OUTCOMES = %i[accepted rejected].freeze

    # The response to a claim submission — 999 and/or 277CA collapsed into one
    # answer to "did this claim get in the door?".
    Acknowledgment = Data.define(
      :claim_identifier,
      :trace_number,
      :outcome,
      :transaction_set,
      :received_at,
      :edits
    ) do
      def initialize(claim_identifier:, trace_number:, outcome:,
                     transaction_set: "277CA", received_at: nil, edits: [])
        unless ACKNOWLEDGMENT_OUTCOMES.include?(outcome)
          raise ArgumentError, "unknown acknowledgment outcome #{outcome.inspect}"
        end

        super
      end

      def accepted?
        outcome == :accepted
      end

      # A rejected claim was never adjudicated. `denied?` deliberately does not
      # exist on this type.
      def rejected?
        outcome == :rejected
      end

      # What a human is supposed to do next. A rejection is always
      # fix-and-resubmit — never appeal.
      def disposition
        rejected? ? :fix_and_resubmit : :awaiting_adjudication
      end

      def work_queue
        rejected? ? :claim_rework : nil
      end

      def reasons
        Array(edits).map(&:to_s)
      end
    end
  end
end
