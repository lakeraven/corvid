# frozen_string_literal: true

module Corvid
  # corvid#595: submits a Medicaid claim for a PRC referral — gated on
  # fulfilment (care actually recorded as delivered), never on
  # authorization alone. Authorization answers "may we pay for this";
  # fulfilment answers "did it happen"; a claim must only be billable once
  # both are true. Unlike ClaimSubmission.create! directly, this is the
  # one path that enforces that gate and attaches the structural referral
  # association in one place.
  class MedicaidReferralBilling
    class SubmissionRejected < StandardError; end

    class << self
      def submit_claim!(referral:, cpt_code:, charge:, provider_identifier:)
        reject_unless_fulfilled!(referral)

        claim = Corvid::ClaimSubmission.create!(
          tenant_identifier: referral.tenant_identifier,
          facility_identifier: referral.facility_identifier,
          patient_identifier: referral.case.patient_identifier,
          prc_referral: referral,
          referral_identifier: referral.referral_identifier,
          claim_type: "professional",
          status: "draft",
          billed_amount: charge,
          payer_identifier: "medicaid",
          service_date: Date.current,
          provider_identifier: provider_identifier,
          procedure_codes_token: Corvid.adapter.store_text(
            case_token: referral.case&.id&.to_s || "unknown",
            kind: :procedure_code,
            text: cpt_code
          )
        )
        claim.submit!
        claim
      end

      private

      def reject_unless_fulfilled!(referral)
        return if Corvid::ReferralFulfilment.billable_for_delivered_care?(referral)

        raise SubmissionRejected,
          "Medicaid claim for referral #{referral.referral_identifier} rejected: " \
          "fulfilment has not recorded delivered care " \
          "(status=#{Corvid::ReferralFulfilment.status(referral)})"
      end
    end
  end
end
