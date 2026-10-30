# frozen_string_literal: true

require "bigdecimal"

require_relative "remittance"

module Corvid
  module Rcm
    # Procedure code and service date for one adjudicated line. A posting
    # entry never carries a patient identifier; this is the only line detail
    # the ledger needs.
    PostingServiceLine = Data.define(:procedure_code, :serviced_date)

    # One ledger-neutral amount from one claim. `service_line` is nil when
    # the amount sits on the claim. `group_code` and `reason_code` are nil
    # on a payer payment (and on the reversal of one).
    PostingEntry = Data.define(
      :claim_identifier,
      :payer_control_number,
      :kind,
      :amount,
      :group_code,
      :reason_code,
      :service_line
    )

    # A claim that must not be posted. `unexplained_amount` is the arithmetic
    # gap (billed minus paid minus adjustments). A row is also returned when
    # that gap is zero but the service lines disagree with the claim payment,
    # or a reversal was paid a positive amount.
    UnbalancedClaim = Data.define(
      :claim_identifier,
      :payer_control_number,
      :unexplained_amount
    )

    # Ledger-neutral posting entries for one remittance.
    #
    # A claim is posted only when billed equals paid plus every CAS
    # adjustment, any service lines' paid amounts sum to the claim paid
    # amount, and a reversal (CLP02 = 22) was not paid a positive amount.
    # Otherwise it is returned on #unbalanced and contributes nothing to
    # #entries. Other claims in the same remittance still post.
    #
    # Reversal entries keep the amounts the remittance reported. On a
    # takeback those amounts are already negative; they are not negated
    # again. Every adjustment is kept, including a zero amount. A zero
    # payer payment is omitted.
    PostingPlan = Data.define(:entries, :unbalanced) do
      # CAS group code -> posting kind. Any other group is :unclassified
      # and is still posted. A balanced claim never drops an adjustment.
      GROUP_KINDS = {
        ADJUSTMENT_GROUP_CONTRACTUAL => :contractual_adjustment,
        ADJUSTMENT_GROUP_PATIENT_RESPONSIBILITY => :patient_responsibility,
        "OI" => :other_payer,
        ADJUSTMENT_GROUP_PAYER_INITIATED => :payer_initiated_reduction
      }.freeze

      def self.from(remittance)
        entries = []
        unbalanced = []
        Array(remittance.claims).each { |claim| collect(claim, entries, unbalanced) }
        new(entries: entries.freeze, unbalanced: unbalanced.freeze)
      end

      # The posting entries. Present so a plan can be walked like the list
      # of money it decided to post.
      def to_a
        entries
      end

      def self.collect(claim, entries, unbalanced)
        if postable?(claim)
          entries.concat(rows_for(claim))
        else
          unbalanced << unbalanced_claim(claim)
        end
      end

      def self.postable?(claim)
        claim.balanced? && service_payments_match?(claim) && !positive_reversal?(claim)
      end

      def self.service_payments_match?(claim)
        services = Array(claim.services)
        services.empty? || services.sum(BigDecimal(0), &:paid_amount) == claim.paid_amount
      end

      def self.positive_reversal?(claim)
        claim.reversal? && claim.paid_amount.positive?
      end

      def self.unbalanced_claim(claim)
        UnbalancedClaim.new(
          claim_identifier: claim.claim_identifier,
          payer_control_number: claim.payer_control_number,
          unexplained_amount: claim.unexplained_amount
        )
      end

      def self.rows_for(claim)
        reversal = claim.reversal?
        services = Array(claim.services)
        rows = services.flat_map { |service| service_rows(claim, service, reversal) }
        rows.concat(adjustment_rows(claim, nil, claim.adjustments, reversal))
        append_claim_payment(rows, claim, reversal) if services.empty?
        rows
      end

      def self.append_claim_payment(rows, claim, reversal)
        return if claim.paid_amount.zero?

        rows.unshift(payment_row(claim, nil, claim.paid_amount, reversal))
      end

      def self.service_rows(claim, service, reversal)
        line = PostingServiceLine.new(
          procedure_code: service.procedure_code,
          serviced_date: service.serviced_date
        )
        rows = adjustment_rows(claim, line, service.adjustments, reversal)
        return rows if service.paid_amount.zero?

        rows.unshift(payment_row(claim, line, service.paid_amount, reversal))
      end

      def self.adjustment_rows(claim, line, adjustments, reversal)
        Array(adjustments).map { |adjustment| adjustment_row(claim, line, adjustment, reversal) }
      end

      def self.payment_row(claim, line, amount, reversal)
        build_entry(claim, kind: reversal ? :reversal : :payer_payment, amount: amount,
                    group_code: nil, reason_code: nil, service_line: line)
      end

      def self.adjustment_row(claim, line, adjustment, reversal)
        build_entry(claim, kind: kind_for(adjustment.group_code, reversal), amount: adjustment.amount,
                    group_code: adjustment.group_code, reason_code: adjustment.reason_code,
                    service_line: line)
      end

      def self.kind_for(group_code, reversal)
        return :reversal if reversal

        GROUP_KINDS.fetch(group_code, :unclassified)
      end

      def self.build_entry(claim, kind:, amount:, group_code:, reason_code:, service_line:)
        PostingEntry.new(
          claim_identifier: claim.claim_identifier,
          payer_control_number: claim.payer_control_number,
          kind: kind,
          amount: amount,
          group_code: group_code,
          reason_code: reason_code,
          service_line: service_line
        )
      end

      private_class_method :collect, :postable?, :service_payments_match?, :positive_reversal?,
                           :unbalanced_claim, :rows_for, :append_claim_payment, :service_rows,
                           :adjustment_rows, :payment_row, :adjustment_row, :kind_for, :build_entry
    end
  end
end
