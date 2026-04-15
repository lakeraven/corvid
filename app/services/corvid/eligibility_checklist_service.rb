# frozen_string_literal: true

module Corvid
  # Orchestrates populating and updating the PRC eligibility checklist.
  # Calls the adapter for enrollment, identity, and residency verification
  # to auto-fill items that can be verified programmatically. Remaining
  # items are completed manually by staff.
  class EligibilityChecklistService
    class << self
      # Auto-populate a checklist from the enrollment adapter. Creates
      # the checklist if it doesn't exist. Returns the checklist.
      def populate!(referral)
        checklist = referral.eligibility_checklist ||
          referral.create_eligibility_checklist!(
            tenant_identifier: referral.tenant_identifier,
            facility_identifier: referral.facility_identifier
          )

        patient_id = referral.case.patient_identifier
        adapter_name = Corvid.adapter.class.name.demodulize.underscore.sub(/_adapter$/, "")

        populate_enrollment!(checklist, patient_id, adapter_name)
        populate_identity!(checklist, patient_id, adapter_name)
        populate_residency!(checklist, patient_id, adapter_name)

        checklist.reload
      rescue ActiveRecord::RecordNotUnique
        # Concurrent call already created the checklist; reload and populate
        referral.reload
        retry
      end

      # Manually verify a single checklist item.
      def verify_item!(referral, item, source: nil, by: nil)
        checklist = referral.eligibility_checklist
        raise ArgumentError, "No eligibility checklist for referral #{referral.referral_identifier}" unless checklist

        checklist.verify_item!(item, source: source, by: by)
      end

      # Record management approval on the checklist.
      def approve!(referral, by:)
        checklist = referral.eligibility_checklist
        raise ArgumentError, "No eligibility checklist for referral #{referral.referral_identifier}" unless checklist

        checklist.verify_item!(:management_approved, by: by)
      end

      private

      def populate_enrollment!(checklist, patient_id, source)
        return if checklist.enrollment_verified

        result = Corvid.adapter.verify_tribal_enrollment(patient_id)
        return unless result[:enrolled]

        checklist.verify_item!(:enrollment_verified, source: source)
      end

      def populate_identity!(checklist, patient_id, source)
        return if checklist.identity_verified

        result = Corvid.adapter.verify_identity_documents(patient_id)
        return unless result[:ssn_present] || result[:dob_present]

        checklist.verify_item!(:identity_verified, source: source)
      end

      def populate_residency!(checklist, patient_id, source)
        return if checklist.residency_verified

        result = Corvid.adapter.verify_residency(patient_id)
        return unless result[:on_reservation]

        checklist.verify_item!(:residency_verified, source: source)
      end
    end
  end
end
