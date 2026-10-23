# frozen_string_literal: true

module Corvid
  # Authorizes a referral with Medicaid paying first.
  #
  # Primary payer is the coordinated Medicaid AlternateResourceCheck.
  # There is no primary_payer column. A recorded enrolled or coordinated
  # answer is used as-is only when current_for?(Date.current). Otherwise
  # it is re-verified through the injected adapter and refused unless
  # that fresh answer is enrolled or coordinated and current_for? today.
  # A refusal raises Refused and persists nothing.
  #
  # An estimated cost that is nil on the referral and nil from the
  # adapter is unknown. A medical priority that is nil on the referral
  # and nil from the adapter is unknown too. The adapter priority is
  # service_request.medical_priority_level, the same lookup
  # PrcReferral uses for its priority cache. When nothing else requires
  # committee review, that unknown cost or priority is refused before
  # any transition, so nothing is persisted.
  #
  # From priority_assignment the guarded event is
  # complete_priority_assignment!, which sends requires_committee?
  # referrals to committee_review. authorize! is not used, so committee
  # review is never skipped. Already being in committee_review is
  # refused the same way. The lock runs inside a savepoint
  # (transaction requires_new) so a Refused rescued inside a caller's
  # transaction persists nothing: no coordination, no authorization,
  # no state change. When Refused or any other error escapes that
  # savepoint, the caller's referral is reloaded so its status, AASM
  # state, and checks match the database.
  #
  # The adapter is injected per ADR 0005. Model callbacks that still
  # reach Corvid.adapter are the #264 gap.
  class MedicaidReferralWorkflow
    # Why authorization did not happen. Resource type and status only,
    # or committee review. No patient, payer, or policy data (ADR 0003).
    class Refused < StandardError; end

    def initialize(adapter: Corvid.adapter)
      @adapter = adapter
    end

    def authorize_with_medicaid_primary!(referral)
      referral.transaction(requires_new: true) do
        referral.with_lock do
          coordinate_medicaid_primary!(referral)
          advance_to_authorizable_state!(referral)
          finish_priority_assignment!(referral)
        end
      end
    rescue StandardError
      # Savepoint rollback restores the row, not this instance. A later
      # authorize! would otherwise leave a state the database never had.
      referral.reload
      raise
    end

    private

    attr_reader :adapter

    def coordinate_medicaid_primary!(referral)
      medicaid = locked_medicaid_check(referral)
      raise Refused, medicaid_refusal_message(referral, medicaid) if medicaid.nil?

      if medicaid_needs_reverification?(medicaid)
        accept_reverified_medicaid!(referral, medicaid)
      else
        accept_recorded_medicaid!(referral, medicaid)
      end
    end

    def locked_medicaid_check(referral)
      referral.alternate_resource_checks.lock.find_by(resource_type: "medicaid")
    end

    # Only an enrolled or coordinated row can be re-asked, and only
    # when it is not current for today. Checking and not_enrolled are
    # refused as they stand.
    def medicaid_needs_reverification?(medicaid)
      return false unless medicaid.enrolled? || medicaid.coordinated?

      !medicaid.current_for?(Date.current)
    end

    # verify! returns false and writes nothing when the adapter's answer
    # is unreadable. Silence is not a current enrollment.
    def accept_reverified_medicaid!(referral, medicaid)
      medicaid.verify!(adapter: adapter)
      referral.alternate_resource_checks.reset
      return if medicaid.coordinated? && medicaid.current_for?(Date.current)
      return mark_medicaid_coordinated!(referral, medicaid) if fresh_enrolled?(medicaid)

      raise Refused, medicaid_refusal_message(referral, medicaid)
    end

    def fresh_enrolled?(medicaid)
      medicaid.enrolled? && medicaid.current_for?(Date.current)
    end

    def accept_recorded_medicaid!(referral, medicaid)
      return if medicaid.coordinated?
      return mark_medicaid_coordinated!(referral, medicaid) if medicaid.enrolled?

      raise Refused, medicaid_refusal_message(referral, medicaid)
    end

    def mark_medicaid_coordinated!(referral, medicaid)
      medicaid.mark_coordinated!
      referral.alternate_resource_checks.reset
    end

    # alternate_resource_review cannot take complete_priority_assignment.
    # The exhaustion guard on verify_alternate_resources! is the step
    # into priority_assignment. It is not itself authorization.
    def advance_to_authorizable_state!(referral)
      return unless referral.may_verify_alternate_resources?

      referral.verify_alternate_resources!
    end

    # complete_priority_assignment! routes requires_committee? referrals
    # to committee_review and everyone else to authorized. authorize!
    # would skip that fork. Unknown cost and unknown priority are
    # refused before that event when nothing else requires committee
    # review. Landing in committee_review, already being there, or
    # still requiring committee review persists nothing.
    def finish_priority_assignment!(referral)
      raise Refused, committee_review_refusal if referral.committee_review?
      raise Refused, unknown_cost_refusal if refuses_for_unknown_cost?(referral)
      raise Refused, unknown_priority_refusal if refuses_for_unknown_priority?(referral)

      referral.complete_priority_assignment! if referral.may_complete_priority_assignment?
      return if referral.authorized?

      raise Refused, committee_review_refusal if committee_review_unresolved?(referral)
      raise Refused, blocked_authorization_message(referral)
    end

    # Nil on the referral and nil from the adapter. A priority or a
    # review flag still takes the committee path.
    def refuses_for_unknown_cost?(referral)
      return false if referral.requires_committee?

      referral.estimated_cost.nil? && referral.service_request&.estimated_cost.nil?
    end

    def unknown_cost_refusal
      "unknown cost"
    end

    # Nil locally and nil from the adapter. Same read as
    # PrcReferral#cached_medical_priority. Cost or a review flag still
    # takes the committee path. Checked after unknown cost so a referral
    # missing both is named for the cost.
    def refuses_for_unknown_priority?(referral)
      return false if referral.requires_committee?

      referral.medical_priority.nil? && referral.service_request&.medical_priority_level.nil?
    end

    def unknown_priority_refusal
      "unknown priority"
    end

    def committee_review_unresolved?(referral)
      referral.committee_review? || referral.requires_committee?
    end

    def committee_review_refusal
      "committee review required"
    end

    def blocked_authorization_message(referral)
      blockers = referral.authorization_blockers
      state = "referral: #{referral.status}"
      return state if blockers.empty?

      "#{blockers.join('; ')}; #{state}"
    end

    def medicaid_refusal_message(referral, medicaid)
      detail = medicaid_refusal_detail(medicaid)
      extras = referral.authorization_blockers.reject { |blocker| blocker.include?(detail) }
      ([ "Medicaid is not active coverage (#{detail})" ] + extras).join("; ")
    end

    def medicaid_refusal_detail(medicaid)
      return "medicaid: not checked" if medicaid.nil?
      return "medicaid: not current" if recorded_coverage_not_current?(medicaid)

      "medicaid: #{medicaid.status.to_s.tr("_", " ")}"
    end

    def recorded_coverage_not_current?(medicaid)
      (medicaid.enrolled? || medicaid.coordinated?) && !medicaid.current_for?(Date.current)
    end
  end
end
