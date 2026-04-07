# frozen_string_literal: true

module Corvid
  # Walks the user through creating a PRC referral.
  # Calls the adapter to create the referral in the EHR, then creates
  # the local Case-domain PrcReferral record with the returned identifier.
  class AuthorizationWizard
    attr_reader :patient_identifier, :facility_identifier, :user_identifier, :data, :prc_referral

    def initialize(patient_identifier:, facility_identifier:, user_identifier:)
      @patient_identifier = patient_identifier
      @facility_identifier = facility_identifier
      @user_identifier = user_identifier
      @data = {}
      @prc_referral = nil
    end

    def submit!
      patient_case = Corvid::Case.find_or_create_by!(
        patient_identifier: patient_identifier,
        facility_identifier: facility_identifier
      )

      new_referral_identifier = Corvid.adapter.create_referral(patient_identifier, {
        reason: data[:reason_for_referral] || data[:service_requested],
        urgency: data[:urgency],
        requesting_provider_identifier: user_identifier,
        estimated_cost: data[:estimated_cost]
      })

      unless new_referral_identifier.present?
        return { success: false, errors: [ "EHR referral creation failed" ] }
      end

      @prc_referral = Corvid::PrcReferral.create!(
        case: patient_case,
        facility_identifier: facility_identifier,
        referral_identifier: new_referral_identifier,
        estimated_cost: data[:estimated_cost],
        medical_priority: data[:medical_priority]
      )

      { success: true, referral: @prc_referral }
    rescue => e
      { success: false, errors: [ Corvid.sanitize_phi(e.message) ] }
    end
  end
end
