# frozen_string_literal: true

module Corvid
  # Deterministic FMAP classification (#546). Applies the FmapRules in
  # force on the encounter's date of service — never today's rules — and
  # reports, alongside the evidence-supported category, the best category
  # available had all evidence been present, plus what is missing. No
  # silent inference: an unevidenced 100% is reported as a gap with the
  # missing evidence named, never granted, and an encounter no in-force
  # rule covers comes back UNDETERMINED with a reason — never a
  # definitive category a CMS-64 run would read as settled.
  class FmapClassificationService
    UNDETERMINED = "undetermined"

    # Reasons a result carries no applied rule, or carries a lower one
    # than the inputs superficially suggest. Persisted with the
    # determination so an audit sees why, not just what.
    NO_RULES_IN_FORCE = "no_rules_in_force"
    NO_MATCHING_RULE = "no_matching_rule"
    UNEVIDENCED_100 = "unevidenced_100_percent"

    Result = Struct.new(
      :category, :fmap_percent, :rule_key, :rule_citations,
      :best_available_category, :best_available_rule_key, :missing_evidence,
      :state_share_delta_cents, :determination_reason,
      keyword_init: true
    ) do
      def misclassification_gap?
        best_available_category.present? && best_available_category != category
      end

      def undetermined?
        category == UNDETERMINED
      end
    end

    class << self
      def classify(date_of_service:, jurisdiction:, facility_authority: nil,
                   aian_verified: false, received_through_basis: nil,
                   coverage_group: nil, billed_amount_cents: nil,
                   evidence_refs: [])
        authority_type = authority_type_in_force(facility_authority, date_of_service)
        basis = received_through_basis.presence || (authority_type ? "facility_authority" : nil)

        rules = FmapRule.in_force_on(date_of_service).for_jurisdiction(jurisdiction).to_a

        # An unloaded (or wholly end-dated) rule set is a broken input,
        # not a finding of "not Medicaid". Say so loudly and refuse.
        if rules.empty?
          warn_no_rules(date_of_service, jurisdiction)
          return undetermined_result(NO_RULES_IN_FORCE)
        end

        matched = best_match(rules, authority_type: authority_type, aian_verified: aian_verified,
                                    basis: basis, coverage_group: coverage_group)
        best = best_match(rules, authority_type: authority_type, aian_verified: true,
                                 basis: basis, coverage_group: coverage_group)

        # The 100 percent tiers are the ones that move federal dollars,
        # so they are the ones that must rest on a persisted evidence
        # chain. Without one, fall back to the highest *evidenced* tier
        # the same inputs support, or refuse — never grant.
        actual = matched
        reason = nil
        if matched&.hundred_percent? && evidence_refs.blank?
          reason = UNEVIDENCED_100
          actual = best_match(rules.reject(&:hundred_percent?), authority_type: authority_type,
                              aian_verified: aian_verified, basis: basis, coverage_group: coverage_group)
        end

        return undetermined_result(reason || NO_MATCHING_RULE, best: best) if actual.nil?

        Result.new(
          category: actual.category,
          fmap_percent: actual.fmap_percent,
          rule_key: actual.rule_key,
          rule_citations: [ actual.statutory_citation ],
          best_available_category: best&.category,
          best_available_rule_key: best&.rule_key,
          missing_evidence: missing_evidence(best, actual, aian_verified: aian_verified,
                                                           basis: basis, reason: reason),
          state_share_delta_cents: delta_cents(actual, best, billed_amount_cents),
          determination_reason: reason
        )
      end

      # Classify and persist the determination as the audit artifact.
      # The evidence refs are both the classification input (a 100
      # percent tier is unreachable without them) and the persisted
      # chain the determination rests on.
      def classify!(encounter_identifier:, person_identifier: nil, facility_identifier: nil,
                    evidence_refs: [], claim_reference: nil, **classify_opts)
        result = classify(evidence_refs: evidence_refs, **classify_opts)

        FmapDetermination.create!(
          encounter_identifier: encounter_identifier,
          person_identifier: person_identifier,
          facility_identifier: facility_identifier,
          date_of_service: classify_opts.fetch(:date_of_service),
          jurisdiction: classify_opts.fetch(:jurisdiction),
          category: result.category,
          fmap_percent: result.fmap_percent,
          rule_key: result.rule_key,
          rule_citations: result.rule_citations,
          evidence_refs: evidence_refs,
          aian_verified: classify_opts.fetch(:aian_verified, false),
          received_through_basis: classify_opts[:received_through_basis],
          coverage_group: classify_opts[:coverage_group],
          best_available_category: result.best_available_category,
          best_available_rule_key: result.best_available_rule_key,
          missing_evidence: result.missing_evidence,
          state_share_delta_cents: result.state_share_delta_cents,
          determination_reason: result.determination_reason,
          claim_reference: claim_reference,
          determined_at: Time.current
        )
      end

      private

      # A refusal, not a category: no percent, no rule, no citation. The
      # best-available lens still reports what full evidence would have
      # reached, so the gap is visible rather than silently absent.
      def undetermined_result(reason, best: nil)
        Result.new(
          category: UNDETERMINED,
          fmap_percent: nil,
          rule_key: nil,
          rule_citations: [],
          best_available_category: best&.category,
          best_available_rule_key: best&.rule_key,
          missing_evidence: reason == UNEVIDENCED_100 ? [ "evidence_refs" ] : [],
          state_share_delta_cents: nil,
          determination_reason: reason
        )
      end

      def warn_no_rules(date_of_service, jurisdiction)
        return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.error(
          "[Corvid::FmapClassificationService] no FMAP rules in force for " \
          "jurisdiction=#{jurisdiction} date_of_service=#{date_of_service}; " \
          "classification refused (load rules via Corvid::FmapRuleLoader.load_defaults!)"
        )
      end

      def authority_type_in_force(facility_authority, date)
        return nil unless facility_authority&.in_force_on?(date)
        facility_authority.authority_type
      end

      def best_match(rules, authority_type:, aian_verified:, basis:, coverage_group:)
        rules
          .select { |rule|
            rule.matches?(
              facility_authority_type: authority_type,
              aian_verified: aian_verified,
              received_through_basis: basis,
              coverage_group: coverage_group
            )
          }
          .max_by(&:specificity)
      end

      def missing_evidence(best, actual, aian_verified:, basis:, reason: nil)
        missing = []
        missing << "evidence_refs" if reason == UNEVIDENCED_100
        return missing if best.nil? || best == actual

        missing << "aian_attestation" if best.requires_aian && !aian_verified
        missing << "received_through_basis" if best.requires_received_through && basis.blank?
        missing
      end

      # Quantifiable state-share gap, computable only when both the actual
      # and best-available rules carry a percent (the regular-FMAP percent
      # is state/year data supplied by jurisdiction packs; absent that,
      # the delta is reported as unknown rather than guessed).
      def delta_cents(actual, best, billed_amount_cents)
        return nil if billed_amount_cents.nil? || actual.nil? || best.nil?
        return nil if actual.fmap_percent.nil? || best.fmap_percent.nil?
        return nil if best.fmap_percent <= actual.fmap_percent

        ((best.fmap_percent - actual.fmap_percent) * billed_amount_cents / 100).round
      end
    end
  end
end
