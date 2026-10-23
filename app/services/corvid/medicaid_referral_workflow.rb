# frozen_string_literal: true

module Corvid
  # Authorizes a referral with Medicaid paying first.
  #
  # Primary payer is the coordinated Medicaid AlternateResourceCheck.
  # There is no primary_payer column. An enrolled check is coordinated
  # when that recorded answer is still usable: checked_at is present and
  # inside the configured age, and any stored coverage period or renewal
  # still covers today. A missing period is not a past period. When the
  # answer is not usable (stale or nil checked_at, or a period that does
  # not cover today), it is re-verified through the injected adapter and
  # coordinated only if that fresh answer is enrolled and current_for?
  # today. A refusal raises Refused and persists nothing.
  #
  # From priority_assignment the guarded event is
  # complete_priority_assignment!, which sends requires_committee?
  # referrals to committee_review. authorize! is not used, so committee
  # review is never skipped. Already being in committee_review is
  # refused the same way. The lock runs inside a savepoint
  # (transaction requires_new) so a Refused rescued inside a caller's
  # transaction persists nothing: no coordination, no authorization,
  # no state change.
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

    # Only an enrolled or coordinated row can be re-asked. Checking and
    # not_enrolled are refused as they stand.
    def medicaid_needs_reverification?(medicaid)
      return false unless medicaid.enrolled? || medicaid.coordinated?

      !recorded_answer_usable?(medicaid)
    end

    # Fresh, and any stored period or renewal still covers today.
    # Both coverage dates nil is not a lapsed period.
    def recorded_answer_usable?(medicaid)
      !determination_aged_out?(medicaid) &&
        !coverage_period_excludes_today?(medicaid) &&
        !renewal_excludes_today?(medicaid)
    end

    def determination_aged_out?(check)
      max_age = Corvid.configuration.alternate_resource_check_max_age.fetch(check.resource_type)
      check.stale?(max_age: max_age)
    end

    def coverage_period_excludes_today?(check)
      return false if check.coverage_start.nil? && check.coverage_end.nil?

      today = Date.current
      starts_later = check.coverage_start.present? && check.coverage_start > today
      ends_earlier = check.coverage_end.present? && check.coverage_end < today
      starts_later || ends_earlier
    end

    def renewal_excludes_today?(check)
      check.renewal_date.present? && check.renewal_date < Date.current
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
    # would skip that fork. Landing in committee_review, already being
    # there, or still requiring committee review persists nothing.
    def finish_priority_assignment!(referral)
      raise Refused, committee_review_refusal if referral.committee_review?

      referral.complete_priority_assignment! if referral.may_complete_priority_assignment?
      return if referral.authorized?

      raise Refused, committee_review_refusal if committee_review_unresolved?(referral)
      raise Refused, blocked_authorization_message(referral)
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
