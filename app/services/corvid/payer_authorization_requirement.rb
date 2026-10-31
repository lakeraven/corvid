# frozen_string_literal: true

module Corvid
  # Resolves the authorization requirement for one payer, service, and
  # day. No matching rule is unknown, never not_required: absence is not
  # evidence that authorization is unnecessary. Two maximal rules that
  # disagree are conflict. A rule is possibly applicable when it matches
  # payer, code, and date and, for each of plan and place, its value is
  # blank, equals the input, or the input is omitted. If any such rule
  # is not a confirmed match and names a different requirement, the
  # answer is unknown. A conflict stays a conflict.
  class PayerAuthorizationRequirement
    Result = Data.define(:requirement, :rule_ids) do
      def initialize(requirement:, rule_ids:)
        super(requirement: requirement, rule_ids: rule_ids.sort.freeze)
        freeze
      end
    end

    def self.lookup(payer_identifier:, service_code:, place_of_service:, plan_identifier:, on:,
                    tenant_identifier: Corvid::TenantContext.current_tenant_identifier)
      new(
        payer_identifier: payer_identifier,
        service_code: service_code,
        place_of_service: place_of_service,
        plan_identifier: plan_identifier,
        on: on,
        tenant_identifier: tenant_identifier
      ).call
    end

    def initialize(payer_identifier:, service_code:, place_of_service:, plan_identifier:, on:, tenant_identifier:)
      @payer = payer_identifier.to_s.strip
      @code = PayerAuthorizationRule.normalize_code(service_code) || ""
      @place = present_or_nil(place_of_service)
      @plan = present_or_nil(plan_identifier)
      @on = on
      @tenant = tenant_identifier.to_s.strip
    end

    def call
      return unknown unless decidable?

      scoped = rules_for_code_and_date
      matched = scoped.select { |rule| place_matches?(rule) && plan_matches?(rule) }
      close_gaps(decision(matched), scoped, matched)
    end

    private

    def decidable?
      @tenant.present? && @payer.present? && @code.match?(PayerAuthorizationRule::CODE_FORMAT) && @on.instance_of?(Date)
    end

    def present_or_nil(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end

    def unknown
      Result.new(requirement: :unknown, rule_ids: [])
    end

    # Explicit tenant filter. unscoped so the thread's tenant cannot
    # hide the tenant the caller named, including when no context is set.
    def payer_rules
      PayerAuthorizationRule.unscoped.where(
        tenant_identifier: @tenant,
        payer_identifier: @payer
      ).to_a
    end

    def rules_for_code_and_date
      payer_rules.select { |rule| code_matches?(rule) && in_force?(rule) }
    end

    def code_matches?(rule)
      if rule.service_code.present?
        rule.service_code == @code
      else
        range_covers?(rule)
      end
    end

    # String order is not enough: "2033F" sits between "10000" and
    # "69999". The code has to share the endpoints' digit and letter
    # positions. A letter both endpoints share is fixed too, so
    # "0001F".."9999F" covers "2033F" and not "0001T" or "2033G".
    # "A0000".."C9999" shares no first letter, so it still covers
    # "B1234". Endpoints whose patterns disagree match nothing.
    def range_covers?(rule)
      from = rule.code_from
      to = rule.code_to
      return false if from.blank? || to.blank?
      return false unless PayerAuthorizationRule.same_code_pattern?(from, to, @code)
      return false unless fixed_letters_match?(from, to)

      from <= @code && @code <= to
    end

    def fixed_letters_match?(from, to)
      from.each_char.with_index.all? do |from_char, index|
        next true unless same_letter?(from_char, to[index])

        @code[index] == from_char
      end
    end

    def same_letter?(from_char, to_char)
      from_char == to_char && letter?(from_char)
    end

    def letter?(char)
      PayerAuthorizationRule.code_pattern(char) == "A"
    end

    def in_force?(rule)
      rule.effective_on <= @on && (rule.expires_on.nil? || rule.expires_on >= @on)
    end

    def place_matches?(rule)
      rule.place_of_service.blank? || rule.place_of_service == @place
    end

    def plan_matches?(rule)
      rule.plan_identifier.blank? || rule.plan_identifier == @plan
    end

    def decision(matched)
      return unknown if matched.empty?

      chosen = maximal(matched)
      names = chosen.map { |rule| rule.requirement.to_sym }.uniq
      requirement = names.one? ? names.first : :conflict
      Result.new(requirement: requirement, rule_ids: chosen.map(&:id))
    end

    # Partial order on (plan specified, place specified, exact code).
    # Maximal rules are the ones nothing else strictly dominates.
    def maximal(rules)
      rules.select { |rule| rules.none? { |other| dominates?(other, rule) } }
    end

    def dominates?(left, right)
      pairs = specificity(left).zip(specificity(right))
      pairs.all? { |stronger, weaker| stronger >= weaker } && pairs.any? { |stronger, weaker| stronger > weaker }
    end

    def specificity(rule)
      [ specified(rule.plan_identifier), specified(rule.place_of_service), specified(rule.service_code) ]
    end

    def specified(value)
      value.present? ? 1 : 0
    end

    # Confirmed matches already compared plan and place. A possibly
    # applicable rule outside that set still names a requirement the
    # omitted inputs did not rule out. A different requirement is
    # unknown. Conflict is unchanged.
    def close_gaps(result, scoped, matched)
      return result if result.requirement == :conflict
      return unknown if possibly_applicable_disagrees?(result, scoped, matched)

      result
    end

    # Scoped rules already match payer, code, and date. Each of plan and
    # place is open when the rule leaves it blank, the value equals the
    # input, or the input was omitted.
    def possibly_applicable_disagrees?(result, scoped, matched)
      scoped.any? do |rule|
        possibly_applicable?(rule) && matched.exclude?(rule) && disagrees?(rule, result)
      end
    end

    def possibly_applicable?(rule)
      (plan_matches?(rule) || @plan.nil?) && (place_matches?(rule) || @place.nil?)
    end

    def disagrees?(rule, result)
      rule.requirement.to_sym != result.requirement
    end
  end
end
