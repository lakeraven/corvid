# frozen_string_literal: true

module Corvid
  # Orchestrates the Medicaid-as-primary-payer path through the existing
  # PrcReferral authorization chain. Payer-of-last-resort (42 CFR 136.61):
  # when Medicaid (or any other alternate resource) is active, the
  # programme's capped appropriation must not be obligated — so this
  # class authorizes a Medicaid-funded referral WITHOUT ever calling
  # Corvid::BudgetAvailabilityService.reserve_funds_if_available. The
  # programme-funded path (no alternate payer) keeps calling that
  # explicitly, as it already did before this class existed.
  class MedicaidReferralWorkflow
    DEFAULT_BOOTSTRAP_APPROVER = "sys_medicaid_bootstrap"

    class << self
      def record_medicaid_primary_payer!(referral)
        referral.update!(primary_payer: "medicaid")
      end

      # "programme" is the default, not "medicaid" — a referral that
      # never went through the Medicaid designation path is assumed
      # programme-funded (the payer of last resort), never assumed to
      # have an alternate payer by omission.
      def primary_payer(referral)
        referral.primary_payer || "programme"
      end

      # Drives a referral already sitting in alternate_resource_review
      # through to authorized, as a Medicaid-funded referral — i.e.
      # without ever obligating the programme's own appropriation.
      def authorize_with_medicaid!(referral)
        referral.verify_alternate_resources! if referral.may_verify_alternate_resources?
        referral.complete_priority_assignment! if referral.may_complete_priority_assignment?
        referral.authorize! if referral.may_authorize?
        referral.reload
      end

      # Fast-forwards a freshly created referral straight through
      # eligibility, management approval, Medicaid payer designation, and
      # authorization. For specs (and any caller) that need "an
      # authorized Medicaid-funded referral" as a precondition rather
      # than as the behavior under test — mirrors the step-by-step path
      # above rather than skipping the state machine.
      def bootstrap_authorized_medicaid_referral!(referral, approver: DEFAULT_BOOTSTRAP_APPROVER)
        referral.submit! if referral.may_submit?
        referral.begin_eligibility_review! if referral.may_begin_eligibility_review?
        referral.reload

        complete_eligibility_checklist!(referral)

        referral.request_management_approval! if referral.may_request_management_approval?
        referral.pending_approval_by = approver
        referral.approve_management! if referral.may_approve_management?
        referral.reload

        record_medicaid_primary_payer!(referral)
        authorize_with_medicaid!(referral)
      end

      private

      # begin_eligibility_review already auto-populates what the adapter
      # can verify (identity/enrollment/residency/insurance, when seeded).
      # The bootstrap fills in whatever that didn't cover with an explicit
      # manual verification — never a silent default — so bootstrap works
      # whether or not the caller seeded full enrollment/residency fixtures.
      def complete_eligibility_checklist!(referral)
        checklist = referral.eligibility_checklist ||
          Corvid::EligibilityChecklistService.populate!(referral)

        Corvid::EligibilityChecklistService.verify_item!(referral, :application_complete,
          by: "sys_medicaid_bootstrap") unless checklist.application_complete
        Corvid::EligibilityChecklistService.verify_item!(referral, :identity_verified,
          source: "bootstrap") unless checklist.identity_verified
        Corvid::EligibilityChecklistService.verify_item!(referral, :insurance_verified,
          source: "bootstrap") unless checklist.insurance_verified
        Corvid::EligibilityChecklistService.verify_item!(referral, :residency_verified,
          source: "bootstrap") unless checklist.residency_verified
        Corvid::EligibilityChecklistService.verify_item!(referral, :enrollment_verified,
          source: "bootstrap") unless checklist.enrollment_verified
        Corvid::EligibilityChecklistService.verify_item!(referral, :clinical_necessity_documented,
          source: "bootstrap") unless checklist.clinical_necessity_documented
      end
    end
  end
end
