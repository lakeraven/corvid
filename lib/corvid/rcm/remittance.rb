# frozen_string_literal: true

require "bigdecimal"

module Corvid
  module Rcm
    # Structures derived from an 835 electronic remittance advice. These are
    # adjudication results — see acknowledgment.rb for why a DENIAL here is a
    # different animal from a REJECTION there.
    #
    # FHIR R4 alignment: a `Remittance` is a payment-level envelope
    # (PaymentReconciliation), each `RemittanceClaim` is a `ClaimResponse` /
    # `ExplanationOfBenefit`, each `RemittanceService` is
    # `ClaimResponse.item` / `ExplanationOfBenefit.item`, and each `Adjustment`
    # is `.adjudication` with an `adjudication.reason` carrying the CARC.

    # X12 835 CAS group codes.
    #   CO — Contractual Obligation: provider eats it, patient may not be billed.
    #   PR — Patient Responsibility: deductible / coinsurance / copay.
    #   OA — Other Adjustment, commonly prior-payer impact.
    #   PI — Payer Initiated reduction: provider eats it, patient may not be billed.
    ADJUSTMENT_GROUP_CONTRACTUAL = "CO"
    ADJUSTMENT_GROUP_PATIENT_RESPONSIBILITY = "PR"
    ADJUSTMENT_GROUP_OTHER = "OA"
    ADJUSTMENT_GROUP_PAYER_INITIATED = "PI"

    # PR reason codes that split the patient's share. Everything else under PR
    # is still patient responsibility but is not one of the three buckets a
    # patient statement breaks out.
    PATIENT_RESPONSIBILITY_KINDS = {
      "1" => :deductible,
      "2" => :coinsurance,
      "3" => :copay
    }.freeze

    # X12 835 CAS adjustment. `group_code` is CO/PR/OA/PI, `reason_code` is the
    # CARC. `code` is the canonical "CO-45" form the mapping table is keyed by.
    Adjustment = Data.define(:group_code, :reason_code, :amount, :quantity) do
      def initialize(group_code:, reason_code:, amount:, quantity: nil)
        super
      end

      def code
        "#{group_code}-#{reason_code}"
      end

      def contractual?
        group_code == ADJUSTMENT_GROUP_CONTRACTUAL
      end

      def patient_responsibility?
        group_code == ADJUSTMENT_GROUP_PATIENT_RESPONSIBILITY
      end

      # :deductible / :coinsurance / :copay, or nil when this is not one of the
      # three broken-out patient buckets.
      def patient_responsibility_kind
        return nil unless patient_responsibility?

        PATIENT_RESPONSIBILITY_KINDS[reason_code.to_s]
      end
    end

    # 835 SVC loop — one adjudicated service line. FHIR ClaimResponse.item.
    RemittanceService = Data.define(
      :procedure_code, :modifiers, :billed_amount, :paid_amount, :units,
      :serviced_date, :adjustments, :remark_codes
    ) do
      def initialize(procedure_code:, billed_amount:, paid_amount:, modifiers: [],
                     units: 1, serviced_date: nil, adjustments: [], remark_codes: [])
        super
      end

      def adjustment_codes
        Array(adjustments).map(&:code)
      end

      def patient_responsibility_amount
        Array(adjustments).select(&:patient_responsibility?).sum(BigDecimal(0), &:amount)
      end

      def contractual_amount
        Array(adjustments).select(&:contractual?).sum(BigDecimal(0), &:amount)
      end
    end

    # X12 835 CLP02 claim status codes, only the ones Phase 0 acts on.
    CLAIM_STATUS_PROCESSED_PRIMARY = "1"
    CLAIM_STATUS_PROCESSED_SECONDARY = "2"
    CLAIM_STATUS_DENIED = "4"
    CLAIM_STATUS_REVERSAL = "22"

    # 835 CLP loop — one adjudicated claim. FHIR ClaimResponse.
    RemittanceClaim = Data.define(
      :claim_identifier,
      :payer_control_number,
      :status_code,
      :billed_amount,
      :paid_amount,
      :patient_responsibility_amount,
      :patient_identifier,
      :serviced_date,
      :services,
      :adjustments,
      :remark_codes
    ) do
      def initialize(claim_identifier:, status_code:, billed_amount:, paid_amount:,
                     payer_control_number: nil, patient_responsibility_amount: BigDecimal(0),
                     patient_identifier: nil, serviced_date: nil, services: [],
                     adjustments: [], remark_codes: [])
        super
      end

      # RARC remark codes from the claim-level and service-level LQ segments.
      def all_remark_codes
        (Array(remark_codes) + Array(services).flat_map { |svc| Array(svc.remark_codes) }).uniq
      end

      # Everything that arrives on an 835 has been adjudicated by definition —
      # that is exactly what separates it from an Acknowledgment rejection.
      def adjudicated?
        true
      end

      # A denial is an adjudicated refusal to pay. Payers signal it either with
      # CLP02 = 4 or by paying zero on a line that carries a non-patient
      # adjustment (a zero-pay with only PR adjustments is not a denial — the
      # patient owes it).
      def denied?
        return true if status_code.to_s == CLAIM_STATUS_DENIED

        paid_amount.to_f.zero? && all_adjustments.any? { |adj| !adj.patient_responsibility? }
      end

      def reversal?
        status_code.to_s == CLAIM_STATUS_REVERSAL
      end

      def paid_in_full?
        !denied? && paid_amount.to_f.positive? && total_adjustment_amount.to_f.zero?
      end

      def all_adjustments
        Array(adjustments) + Array(services).flat_map { |svc| Array(svc.adjustments) }
      end

      def adjustment_codes
        all_adjustments.map(&:code).uniq
      end

      def total_adjustment_amount
        all_adjustments.sum(BigDecimal(0), &:amount)
      end

      def contractual_amount
        all_adjustments.select(&:contractual?).sum(BigDecimal(0), &:amount)
      end

      # { deductible:, coinsurance:, copay:, other: } — the PR split a patient
      # statement needs. Buckets with nothing in them are zero, not missing.
      def patient_responsibility_breakdown
        breakdown = { deductible: BigDecimal(0), coinsurance: BigDecimal(0),
                      copay: BigDecimal(0), other: BigDecimal(0) }
        all_adjustments.select(&:patient_responsibility?).each do |adj|
          breakdown[adj.patient_responsibility_kind || :other] += adj.amount
        end
        breakdown
      end
    end

    # 835 transaction envelope — BPR/TRN/N1 header plus the CLP loops.
    Remittance = Data.define(
      :remittance_identifier,
      :payer_name,
      :payee_identifier,
      :payment_method,
      :payment_amount,
      :payment_date,
      :currency,
      :claims
    ) do
      def initialize(remittance_identifier:, payment_amount:, payer_name: nil,
                     payee_identifier: nil, payment_method: nil, payment_date: nil,
                     currency: "USD", claims: [])
        super
      end

      def claim(identifier)
        Array(claims).find { |clm| clm.claim_identifier == identifier }
      end

      def denied_claims
        Array(claims).select(&:denied?)
      end

      # Sum of CLP04 across the claims, which should reconcile to BPR02. A
      # mismatch means the file was mis-parsed or truncated.
      def claims_paid_total
        Array(claims).sum(BigDecimal(0)) { |clm| BigDecimal(clm.paid_amount.to_s) }
      end

      def balanced?
        claims_paid_total == BigDecimal(payment_amount.to_s)
      end
    end
  end
end
