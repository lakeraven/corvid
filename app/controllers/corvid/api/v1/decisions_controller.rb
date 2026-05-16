# frozen_string_literal: true

module Corvid
  module Api
    module V1
      # GET /corvid/api/v1/decisions
      # GET /corvid/api/v1/decisions/:id
      #
      # List + detail for PrcEligibilityDecision rows. List supports
      # query params:
      #   - facility_identifier
      #   - person_identifier
      #   - eligible (true|false)
      #   - decided_after (ISO date)
      #   - decided_before (ISO date)
      class DecisionsController < BaseController
        def index
          scope = Corvid::PrcEligibilityDecision.recent
          scope = scope.where(facility_identifier: params[:facility_identifier]) if params[:facility_identifier].present?
          scope = scope.for_person(params[:person_identifier]) if params[:person_identifier].present?
          if params[:eligible].present?
            scope = ActiveModel::Type::Boolean.new.cast(params[:eligible]) ? scope.eligible : scope.ineligible
          end
          scope = scope.where("decided_at >= ?", Date.parse(params[:decided_after])) if params[:decided_after].present?
          scope = scope.where("decided_at <= ?", Date.parse(params[:decided_before])) if params[:decided_before].present?

          render json: scope.limit(100).map { |d| decision_summary(d) }
        end

        def show
          decision = Corvid::PrcEligibilityDecision.find(params[:id])
          render json: decision_full(decision)
        end

        private

        def decision_summary(d)
          {
            id: d.id,
            person_identifier: d.person_identifier,
            facility_identifier: d.facility_identifier,
            decided_at: d.decided_at.iso8601,
            eligible: d.eligible,
            reason_codes: d.reason_codes,
            provider_confidence: d.provider_confidence
          }
        end

        def decision_full(d)
          decision_summary(d).merge(
            decided_by_identifier: d.decided_by_identifier,
            as_of_date: d.as_of_date.iso8601,
            provider_source: d.provider_source,
            verification_snapshot_hash: d.verification_snapshot_hash
          )
        end
      end
    end
  end
end
