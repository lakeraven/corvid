# frozen_string_literal: true

module Corvid
  module Api
    module V1
      # POST /corvid/api/v1/indian_health_eligibility/inquire
      #
      # Headers, set by the host from the authenticated client:
      #   X-Tenant-Identifier, X-Requester-Identifier, X-Agreement-Reference
      # Body: { "person_identifier": "pt_001" }
      # person_identifier is the host's opaque token (ADR 0003).
      class IndianHealthEligibilityController < BaseController
        FHIR_STATUS = {
          "eligible" => "validated",
          "not_eligible" => "val-fail",
          "unknown" => "in-process"
        }.freeze

        rescue_from Corvid::IndianHealthEligibilityService::SourceUnavailable, with: :render_source_unavailable
        rescue_from Corvid::IndianHealthEligibilityService::CeilingExceeded, with: :render_ceiling_exceeded
        rescue_from Corvid::IndianHealthEligibilityService::CeilingNotConfigured, with: :render_ceiling_missing

        def inquire
          person = params[:person_identifier]
          requester = request.headers["X-Requester-Identifier"]
          agreement = request.headers["X-Agreement-Reference"]
          return render_bad_request unless required_strings?(person, requester, agreement)

          result = inquiry_service.inquire(
            person_identifier: person,
            requester_identifier: requester,
            agreement_reference: agreement
          )
          response.headers["X-Message-Id"] = result.message_id
          render json: inquiry_payload(result)
        end

        private

        def inquiry_service
          Corvid::IndianHealthEligibilityService.new(adapter: Corvid.adapter)
        end

        def required_strings?(*values)
          values.all? { |value| value.is_a?(String) && !value.strip.empty? }
        end

        def inquiry_payload(result)
          {
            message_id: result.message_id,
            answer: result.answer.to_s,
            data_source: result.data_source,
            asserted_at: result.asserted_at&.iso8601,
            verification_result: verification_result(result)
          }
        end

        def verification_result(result)
          body = {
            resourceType: "VerificationResult",
            status: FHIR_STATUS.fetch(result.answer.to_s)
          }
          body[:statusDate] = result.asserted_at.iso8601 if result.asserted_at
          body[:primarySource] = [ { who: { display: result.data_source } } ] if result.data_source
          body
        end

        def render_bad_request
          render json: { error: "person_identifier must be a string and requester headers are required" },
            status: :bad_request
        end

        def render_source_unavailable(error)
          response.headers["X-Message-Id"] = error.message_id
          render json: { error: "eligibility source is unavailable", message_id: error.message_id },
            status: :service_unavailable
        end

        def render_ceiling_exceeded(error)
          response.headers["X-Message-Id"] = error.message_id
          render json: { error: "inquiry ceiling exceeded", message_id: error.message_id },
            status: :too_many_requests
        end

        def render_ceiling_missing(_error)
          render json: { error: "inquiry ceiling is not configured" }, status: :service_unavailable
        end
      end
    end
  end
end
