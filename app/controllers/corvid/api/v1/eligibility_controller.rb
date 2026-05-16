# frozen_string_literal: true

module Corvid
  module Api
    module V1
      # POST /corvid/api/v1/eligibility/check
      #
      # Body shape:
      #   {
      #     "person_identifier": "pt_001",
      #     "facility": {
      #       "identifier": "fac_demo",
      #       "contracted_tribe_code": "DEMO",
      #       "requires_on_reservation": true,
      #       "requires_ssn_on_file": true
      #     },
      #     "as_of_date": "2026-05-16",          # optional, defaults to today
      #     "decided_by_identifier": "user_42"   # optional, host's actor id
      #   }
      class EligibilityController < BaseController
        Facility = Struct.new(
          :identifier,
          :contracted_tribe_code,
          :requires_on_reservation_flag,
          :requires_ssn_on_file_flag,
          keyword_init: true
        ) do
          def requires_on_reservation?
            requires_on_reservation_flag
          end

          def requires_ssn_on_file?
            requires_ssn_on_file_flag
          end
        end

        def check
          facility_hash = check_params[:facility].to_h.symbolize_keys
          facility = Facility.new(
            identifier: facility_hash[:identifier],
            contracted_tribe_code: facility_hash[:contracted_tribe_code],
            requires_on_reservation_flag: facility_hash[:requires_on_reservation],
            requires_ssn_on_file_flag: facility_hash[:requires_ssn_on_file]
          )

          decision = Corvid::TribalEligibilityService.decide(
            person_identifier: check_params[:person_identifier],
            facility: facility,
            as_of_date: check_params[:as_of_date].presence ? Date.parse(check_params[:as_of_date]) : Date.current,
            decided_by_identifier: check_params[:decided_by_identifier]
          )

          render json: decision_response(decision)
        end

        private

        def check_params
          params.permit(
            :person_identifier,
            :as_of_date,
            :decided_by_identifier,
            facility: [ :identifier, :contracted_tribe_code, :requires_on_reservation, :requires_ssn_on_file ]
          )
        end

        def decision_response(decision)
          {
            decision_id: decision.decision_id,
            eligible: decision.eligible,
            reason_codes: decision.reason_codes.map(&:to_s),
            provider_source: decision.provider_source,
            provider_confidence: decision.provider_confidence
          }
        end
      end
    end
  end
end
