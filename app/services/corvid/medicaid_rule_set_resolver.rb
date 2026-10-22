# frozen_string_literal: true

module Corvid
  # Resolves the Medicaid rule set that applies to a member: the renewal
  # cycle, the retroactive coverage window, and whether the work requirement
  # applies, is exempt, is not applicable, or is undetermined.
  #
  # The Indian exemption determination itself comes from the provider
  # (#622, #623) and is passed in. This service does not decide it.
  #
  # Unknown never reads as not exempt. The group's rules are used and
  # exemption_needs_confirmation is set, so the member is not treated as
  # subject to the work requirement until the exemption is confirmed.
  #
  # Fails closed when the state is not configured, the eligibility group is
  # unknown, or the state has no rules for that group: the work requirement
  # is undetermined and the renewal and retroactive windows are absent.
  class MedicaidRuleSetResolver
    EXEMPT_RENEWAL_CYCLE_MONTHS = 12
    ELIGIBILITY_GROUPS = (StateMedicaidRules::GROUPS + %w[unknown]).freeze
    INDIAN_EXEMPTIONS = %w[eligible not_eligible unknown].freeze

    class << self
      def resolve(eligibility_group:, state:, indian_exemption:)
        group_name = recognized(eligibility_group, ELIGIBILITY_GROUPS, "eligibility_group")
        exemption = recognized(indian_exemption, INDIAN_EXEMPTIONS, "indian_exemption")
        entry = StateMedicaidRules.lookup(state)

        return undetermined("state_not_configured", exemption) unless entry.configured?
        return undetermined("eligibility_group_unknown", exemption) if group_name == "unknown"

        group = entry.group(group_name)
        return undetermined("eligibility_group_not_configured", exemption) if group.nil?

        return exempt(group) if exemption == "eligible"

        group_rules(group, exemption)
      end

      private

      def recognized(value, allowed, label)
        text = token_characters(value)
        return text if text && allowed.include?(text)

        raise ArgumentError, "#{label} is not recognized"
      end

      # Read the string's own characters, or Symbol#name. String#to_s can be
      # overridden and would accept a different value.
      def token_characters(value)
        return value.name if value.is_a?(Symbol)

        String.new(value) if value.is_a?(String)
      end

      def undetermined(reason, exemption)
        reasons = [ reason ]
        reasons << "indian_exemption_unconfirmed" if exemption == "unknown"
        rule_set(
          renewal_cycle_months: nil,
          retroactive_window_months: nil,
          work_requirement: "undetermined",
          exemption:,
          reasons:
        )
      end

      def exempt(group)
        rule_set(
          renewal_cycle_months: EXEMPT_RENEWAL_CYCLE_MONTHS,
          retroactive_window_months: group.retro_coverage_months,
          work_requirement: "exempt",
          exemption: "eligible",
          reasons: [ "indian_exemption" ]
        )
      end

      def group_rules(group, exemption)
        reasons = exemption == "unknown" ? [ "indian_exemption_unconfirmed" ] : []
        rule_set(
          renewal_cycle_months: group.renewal_months,
          retroactive_window_months: group.retro_coverage_months,
          work_requirement: group.work_requirement ? "applies" : "not_applicable",
          exemption:,
          reasons:
        )
      end

      def rule_set(renewal_cycle_months:, retroactive_window_months:, work_requirement:, exemption:, reasons:)
        MedicaidRuleSet.new(
          renewal_cycle_months:,
          retroactive_window_months:,
          work_requirement:,
          exemption_needs_confirmation: exemption == "unknown",
          reasons:
        )
      end
    end
  end
end
