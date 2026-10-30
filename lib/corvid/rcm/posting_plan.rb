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
    # that gap is zero but a service line does not balance, the lines' billed
    # amounts do not reconcile to the claim, the lines' paid amounts do not
    # sum to the claim payment, or a reversal reports a positive billed or
    # paid amount.
    UnbalancedClaim = Data.define(
      :claim_identifier,
      :payer_control_number,
      :unexplained_amount
    )

    # Ledger-neutral posting entries for one remittance.
    #
    # A claim is posted only when billed equals paid plus every CAS
    # adjustment. When it has service lines, each line's billed amount must
    # equal that line's paid amount plus its own adjustments, those paid
    # amounts must sum to the claim paid amount, and the lines' billed
    # amounts must sum to the claim billed amount minus claim-level
    # adjustments. A reversal (CLP02 = 22) must report billed and paid
    # amounts that are each less than or equal to zero, and must meet the
    # same claim and line balance rules. Otherwise the claim is returned on
    # #unbalanced and contributes nothing to #entries. Other claims in the
    # same remittance still post.
    #
    # Reversal entries keep the amounts the remittance reported. On a
    # takeback those amounts are already negative; they are not negated
    # again. Every adjustment is kept, including a zero amount. A zero
    # payer payment is omitted.
    PostingPlan = Data.define(:entries, :unbalanced) do
      # X12 CAS group code -> posting kind. CO, PR, OA, and PI become
      # contractual, patient responsibility, other payer, and payer-initiated
      # reduction. Any other group, including OI and CR, is :unclassified and
      # is still posted. A balanced claim never drops an adjustment.
      #
      # const_set: `GROUP_KINDS =` inside this Data.define block binds to
      # Corvid::Rcm, and the table belongs on PostingPlan.
      const_set(:GROUP_KINDS, {
        ADJUSTMENT_GROUP_CONTRACTUAL => :contractual_adjustment,
        ADJUSTMENT_GROUP_PATIENT_RESPONSIBILITY => :patient_responsibility,
        ADJUSTMENT_GROUP_OTHER => :other_payer,
        ADJUSTMENT_GROUP_PAYER_INITIATED => :payer_initiated_reduction
      }.freeze)

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
        claim.balanced? && service_lines_postable?(claim) && reversal_signs_ok?(claim)
      end

      # No service lines: the claim equation is enough. With lines, each line
      # balances on its own, paid amounts sum to the claim payment, and billed
      # amounts sum to the claim billed amount minus claim-level adjustments.
      def self.service_lines_postable?(claim)
        services = Array(claim.services)
        return true if services.empty?

        service_payments_match?(claim) &&
          services.all? { |service| line_balanced?(service) } &&
          line_billed_matches_claim?(claim)
      end

      def self.service_payments_match?(claim)
        services = Array(claim.services)
        services.empty? || services.sum(BigDecimal(0), &:paid_amount) == claim.paid_amount
      end

      def self.line_balanced?(service)
        service.billed_amount == service.paid_amount + adjustment_sum(service.adjustments)
      end

      def self.line_billed_matches_claim?(claim)
        Array(claim.services).sum(BigDecimal(0), &:billed_amount) ==
          claim.billed_amount - adjustment_sum(claim.adjustments)
      end

      def self.adjustment_sum(adjustments)
        Array(adjustments).sum(BigDecimal(0), &:amount)
      end

      # A reversal keeps the reported signs. Billed and paid must each be
      # zero or negative; a positive amount is not a takeback.
      def self.reversal_signs_ok?(claim)
        return true unless claim.reversal?

        claim.billed_amount <= 0 && claim.paid_amount <= 0
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

        self::GROUP_KINDS.fetch(group_code, :unclassified)
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

      private_class_method :collect, :postable?, :service_lines_postable?, :service_payments_match?,
                           :line_balanced?, :line_billed_matches_claim?, :adjustment_sum, :reversal_signs_ok?,
                           :unbalanced_claim, :rows_for, :append_claim_payment, :service_rows,
                           :adjustment_rows, :payment_row, :adjustment_row, :kind_for, :build_entry
    end
  end
end
