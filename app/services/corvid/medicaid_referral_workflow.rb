# frozen_string_literal: true

module Corvid
  # Authorizes a referral with Medicaid paying first.
  #
  # Primary payer is the coordinated Medicaid AlternateResourceCheck.
  # There is no primary_payer column. Coordination (enrolled to
  # coordinated, via AlternateResourceCheck#mark_coordinated!) and the
  # guarded AASM authorize event run in one locked transaction. A
  # refusal raises Refused and persists nothing, coordination included.
  #
  # The adapter is injected per ADR 0005. PrcReferral#authorize! still
  # syncs the EHR through Corvid.adapter in its AASM callback (#264).
  class MedicaidReferralWorkflow
    # Why authorization did not happen: authorization_blockers, Medicaid
    # that is not active coverage, or a workflow state that cannot
    # authorize. Resource type and status only (ADR 0003).
    class Refused < StandardError; end

    def initialize(adapter: Corvid.adapter)
      @adapter = adapter
    end

    def authorize_with_medicaid_primary!(referral)
      referral.with_lock do
        coordinate_medicaid_primary!(referral)
        advance_to_authorizable_state!(referral)
        authorize_guarded!(referral)
      end
    end

    private

    attr_reader :adapter

    def coordinate_medicaid_primary!(referral)
      medicaid = locked_medicaid_check(referral)
      return if medicaid&.coordinated?
      return mark_medicaid_coordinated!(referral, medicaid) if medicaid&.enrolled?

      raise Refused, inactive_medicaid_message(referral, medicaid)
    end

    def locked_medicaid_check(referral)
      referral.alternate_resource_checks.lock.find_by(resource_type: "medicaid")
    end

    def mark_medicaid_coordinated!(referral, medicaid)
      medicaid.mark_coordinated!
      referral.alternate_resource_checks.reset
    end

    # alternate_resource_review cannot take the authorize event. The
    # exhaustion guard on verify_alternate_resources! is the step into a
    # state that event accepts. It is not itself authorization.
    def advance_to_authorizable_state!(referral)
      return unless referral.may_verify_alternate_resources?

      referral.verify_alternate_resources!
    end

    def authorize_guarded!(referral)
      succeeded = referral.may_authorize? && referral.authorize!
      return if succeeded && referral.authorized?

      raise Refused, blocked_authorization_message(referral)
    end

    def blocked_authorization_message(referral)
      blockers = referral.authorization_blockers
      state = "referral: #{referral.status}"
      return state if blockers.empty?

      "#{blockers.join('; ')}; #{state}"
    end

    def inactive_medicaid_message(referral, medicaid)
      detail = medicaid_status_detail(medicaid)
      extras = referral.authorization_blockers.reject { |blocker| blocker.include?(detail) }
      ([ "Medicaid is not active coverage (#{detail})" ] + extras).join("; ")
    end

    def medicaid_status_detail(medicaid)
      return "medicaid: not checked" if medicaid.nil?

      "medicaid: #{medicaid.status.to_s.tr('_', ' ')}"
    end
  end
end
