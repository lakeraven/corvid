# frozen_string_literal: true

module Corvid
  module Api
    module V1
      # POST /corvid/api/v1/aian_exemption/determine
      #
      # Body shape:
      #   {
      #     "person_identifier": "pt_001",
      #     "as_of_date": "2027-03-01",          # optional, defaults to today
      #     "itu_lookback_days": 365,            # optional, state policy
      #     "decided_by_identifier": "user_42"   # optional, host's actor id
      #   }
      #
      # Returns the outcome, the established bases, and the same result as a
      # FHIR R4 VerificationResult for systems that consume FHIR.
      class AianExemptionController < BaseController
        def determine
          person_identifier = determine_params[:person_identifier].presence
          return render(json: { error: "person_identifier is required" }, status: :bad_request) unless person_identifier

          result = Corvid::AianExemptionService.determine(
            person_identifier: person_identifier,
            as_of_date: determine_params[:as_of_date].presence ? Date.parse(determine_params[:as_of_date]) : Date.current,
            itu_lookback_days: determine_params[:itu_lookback_days].presence&.to_i,
            decided_by_identifier: determine_params[:decided_by_identifier]
          )
          row = Corvid::AianExemptionDetermination.find(result.determination_id)

          render json: {
            determination_id: result.determination_id,
            status: result.status.to_s,
            bases: result.bases.map(&:to_s),
            warnings: result.warnings.map(&:to_s),
            verification_result: row.to_fhir_verification_result
          }
        end

        private

        def determine_params
          params.permit(:person_identifier, :as_of_date, :itu_lookback_days, :decided_by_identifier)
        end
      end
    end
  end
end
