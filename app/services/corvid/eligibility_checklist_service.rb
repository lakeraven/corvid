# frozen_string_literal: true

module Corvid
  # Orchestrates populating and updating the PRC eligibility checklist.
  # Calls the adapter for enrollment, identity, and residency verification
  # to auto-fill items that can be verified programmatically. Remaining
  # items are completed manually by staff.
  #
  # Per #222 / ADR 0005: the adapter is injected per-instance rather
  # than reached via the `Corvid.adapter` global. The class-method form
  # accepts an `adapter:` kwarg (defaulting to `Corvid.adapter`) so
  # existing call sites keep working while tests and per-tenant code
  # paths can swap in their own adapters without mutating global state.
  class EligibilityChecklistService
    def initialize(adapter: Corvid.adapter)
      @adapter = adapter
    end

    # Auto-populate a checklist from the enrollment adapter. Creates
    # the checklist if it doesn't exist. Returns the checklist.
    def populate!(referral)
      checklist = referral.eligibility_checklist ||
        referral.create_eligibility_checklist!(
          tenant_identifier: referral.tenant_identifier,
          facility_identifier: referral.facility_identifier
        )

      patient_id = referral.case.patient_identifier
      adapter_name = @adapter.class.name.demodulize.underscore.sub(/_adapter$/, "")

      populate_enrollment!(checklist, patient_id, adapter_name)
      populate_identity!(checklist, patient_id, adapter_name)
      populate_residency!(checklist, patient_id, adapter_name)
      populate_insurance!(checklist, patient_id, adapter_name)

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

    # Staff-triggered payer eligibility check. Calls get_coverages
    # (which may hit a 270/271 clearinghouse — cost-bearing).
    # Only called on demand, not during auto-populate.
    def check_payer_eligibility!(referral)
      checklist = referral.eligibility_checklist
      raise ArgumentError, "No eligibility checklist for referral #{referral.referral_identifier}" unless checklist
      return if checklist.insurance_verified

      # Staff asked for this explicitly. An adapter that cannot query payers
      # must refuse out loud — returning quietly is indistinguishable from
      # "we checked and found no other coverage", which is the answer that
      # lets PRC pay (42 CFR 136.61).
      unless @adapter.supports_coverage_discovery?
        raise CoverageDiscoveryUnavailable,
          "#{@adapter.class.name} cannot query payer coverage, so payer eligibility " \
          "was not checked. This is not a finding of no coverage. Configure an adapter " \
          "that implements #get_coverages before relying on payer-of-last-resort."
      end

      patient_id = referral.case.patient_identifier
      coverages = @adapter.get_coverages(patient_id)
      return unless coverages.is_a?(Array) && coverages.any?

      checklist.verify_item!(:insurance_verified, source: "eligibility_check")
    end

    # Class-method shims for backward compatibility.
    class << self
      def populate!(referral, adapter: Corvid.adapter)
        new(adapter: adapter).populate!(referral)
      end

      def verify_item!(referral, item, source: nil, by: nil, adapter: Corvid.adapter)
        new(adapter: adapter).verify_item!(referral, item, source: source, by: by)
      end

      def approve!(referral, by:, adapter: Corvid.adapter)
        new(adapter: adapter).approve!(referral, by: by)
      end

      def check_payer_eligibility!(referral, adapter: Corvid.adapter)
        new(adapter: adapter).check_payer_eligibility!(referral)
      end
    end

    private

    def populate_enrollment!(checklist, patient_id, source)
      return if checklist.enrollment_verified

      result = @adapter.verify_tribal_enrollment(patient_id)
      # Treat nil / non-hash adapter responses as "verification failed"
      # rather than crashing — adapters reaching across network or
      # backend boundaries can legitimately return nil on lookup miss.
      return unless result.is_a?(Hash) && result[:enrolled]

      checklist.verify_item!(:enrollment_verified, source: source)
    end

    def populate_identity!(checklist, patient_id, source)
      return if checklist.identity_verified

      result = @adapter.verify_identity_documents(patient_id)
      return unless result.is_a?(Hash) && (result[:ssn_present] || result[:dob_present])

      checklist.verify_item!(:identity_verified, source: source)
    end

    def populate_residency!(checklist, patient_id, source)
      return if checklist.residency_verified

      result = @adapter.verify_residency(patient_id)
      return unless result.is_a?(Hash) && result[:on_reservation]

      checklist.verify_item!(:residency_verified, source: source)
    end

    # Auto-populate is best-effort across four items; one unavailable
    # capability must not abort the other three, so this skips rather than
    # raising (unlike the staff-triggered `check_payer_eligibility!`). It
    # says so in the log — silence here is what made the gap invisible.
    def populate_insurance!(checklist, patient_id, source)
      return if checklist.insurance_verified

      unless @adapter.supports_coverage_discovery?
        log_coverage_discovery_unavailable
        return
      end

      coverages = @adapter.get_coverages(patient_id)
      return unless coverages.is_a?(Array) && coverages.any?

      checklist.verify_item!(:insurance_verified, source: source)
    end

    def log_coverage_discovery_unavailable
      return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

      Rails.logger.warn(
        "[corvid] #{@adapter.class.name} cannot query payer coverage; " \
        "insurance_verified left unset. Not a finding of no coverage."
      )
    end
  end
end
