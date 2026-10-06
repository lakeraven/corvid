# frozen_string_literal: true

module Corvid
  # corvid#546: classifies the federal/state match on a Medicaid claim.
  #
  # Prong A (SSA §1905(b)) is settled: medical assistance for services
  # received through an IHS facility, or a facility of a tribe/tribal
  # organization, draws 100% FMAP. Prong B — extending that 100% to an
  # outside (non-tribal) specialist under care coordination for referred
  # care — is NOT settled this session (see features/billing/
  # medicaid_referral_billing.feature header). So this classifier records
  # a determination either way, but only asserts a federal/state split
  # when the claim is tribal-facility-ordered; an outside-specialist claim
  # gets a recorded-but-unresolved determination with that gap named in
  # its basis, never a confident 100% riding on an unverified prong.
  class MedicaidFederalShareClassifier
    Determination = Struct.new(:federal_percent, :state_percent, :basis_tokens, :recorded_at, keyword_init: true)

    SSA_1905B_BASIS = "SSA 1905(b)"
    TRIBAL_FACILITY_BASIS = "tribal_facility"
    AI_AN_BENEFICIARY_BASIS = "ai_an_beneficiary"
    CARE_COORDINATION_PRONG_UNVERIFIED_BASIS = "care_coordination_prong_unverified"

    class << self
      def classify!(claim, tribal_facility_identifier:, patient_identifier:)
        basis = [ SSA_1905B_BASIS ]
        basis << AI_AN_BENEFICIARY_BASIS if ai_an_beneficiary?(patient_identifier)

        # outside_specialist_claim? takes precedence over the facility
        # match below: it answers WHO rendered the care (the referral's
        # service site), which is what Prong B turns on — a claim can be
        # administratively billed under the tribal facility and still
        # have been rendered by a non-tribal specialist.
        if outside_specialist_claim?(claim) || !tribal_facility_claim?(claim, tribal_facility_identifier)
          basis << CARE_COORDINATION_PRONG_UNVERIFIED_BASIS
          return Determination.new(federal_percent: nil, state_percent: nil, basis_tokens: basis,
            recorded_at: Time.current)
        end

        basis << TRIBAL_FACILITY_BASIS
        Determination.new(federal_percent: 100, state_percent: 0, basis_tokens: basis, recorded_at: Time.current)
      end

      private

      def outside_specialist_claim?(claim)
        claim.prc_referral&.service_request&.outside_specialist? || false
      end

      def tribal_facility_claim?(claim, tribal_facility_identifier)
        tribal_facility_identifier.present? && claim.facility_identifier == tribal_facility_identifier
      end

      def ai_an_beneficiary?(patient_identifier)
        Corvid.adapter.find_patient(patient_identifier)&.american_indian_alaska_native? || false
      end
    end
  end
end
