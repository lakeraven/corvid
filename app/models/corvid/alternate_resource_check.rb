# frozen_string_literal: true

module Corvid
  class AlternateResourceCheck < ::ActiveRecord::Base
    self.table_name = "corvid_alternate_resource_checks"

    RESOURCE_TYPES = %w[
      medicare_a medicare_b medicare_d medicaid va_benefits
      private_insurance workers_comp auto_insurance liability_coverage
      state_program tribal_program charity_care
    ].freeze

    belongs_to :prc_referral, class_name: "Corvid::PrcReferral"

    enum :status, {
      not_checked: "not_checked",
      checking: "checking",
      enrolled: "enrolled",
      not_enrolled: "not_enrolled",
      denied: "denied",
      exhausted: "exhausted",
      pending_enrollment: "pending_enrollment"
    }

    validates :resource_type, inclusion: { in: RESOURCE_TYPES }
    validates :resource_type, uniqueness: { scope: :prc_referral_id }

    scope :active_coverage, -> { where(status: %w[enrolled pending_enrollment]) }
    scope :unavailable, -> { where(status: %w[not_enrolled denied exhausted]) }
    scope :federal, -> { where(resource_type: %w[medicare_a medicare_b medicare_d medicaid va_benefits]) }

    def self.create_all_for_referral(prc_referral)
      RESOURCE_TYPES.map do |type|
        prc_referral.alternate_resource_checks.find_or_create_by!(resource_type: type)
      end
    end

    def self.verify_all_for_referral(prc_referral)
      patient_identifier = prc_referral.case&.patient_identifier
      return [] unless patient_identifier

      prc_referral.alternate_resource_checks.map do |check|
        result = Corvid.adapter.verify_eligibility(patient_identifier, check.resource_type)
        if result
          check.update!(
            status: result[:eligible] ? :enrolled : :not_enrolled,
            policy_token: result[:policy_token],
            checked_at: Time.current
          )
        end
        check
      end
    end
  end
end
