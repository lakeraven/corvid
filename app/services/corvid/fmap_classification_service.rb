# frozen_string_literal: true

module Corvid
  # Deterministic FMAP classification (#546). Applies the FmapRules in
  # force on the encounter's date of service — never today's rules — and
  # reports, alongside the evidence-supported category, the best category
  # available had all evidence been present, plus what is missing. No
  # silent inference: an unevidenced 100% is reported as a gap with the
  # missing evidence named, never granted.
  class FmapClassificationService
    Result = Struct.new(
      :category, :fmap_percent, :rule_key, :rule_citations,
      :best_available_category, :best_available_rule_key, :missing_evidence,
      :state_share_delta_cents,
      keyword_init: true
    ) do
      def misclassification_gap?
        best_available_category.present? && best_available_category != category
      end
    end

    class << self
      def classify(date_of_service:, jurisdiction:, facility_authority: nil,
                   aian_verified: false, received_through_basis: nil,
                   coverage_group: nil, billed_amount_cents: nil)
        authority_type = authority_type_in_force(facility_authority, date_of_service)
        basis = received_through_basis.presence || (authority_type ? "facility_authority" : nil)

        rules = FmapRule.in_force_on(date_of_service).for_jurisdiction(jurisdiction).to_a

        actual = best_match(rules, authority_type: authority_type, aian_verified: aian_verified,
                                   basis: basis, coverage_group: coverage_group)
        best = best_match(rules, authority_type: authority_type, aian_verified: true,
                                 basis: basis, coverage_group: coverage_group)

        Result.new(
          category: actual&.category || "non_medicaid",
          fmap_percent: actual&.fmap_percent,
          rule_key: actual&.rule_key,
          rule_citations: actual ? [ actual.statutory_citation ] : [],
          best_available_category: best&.category,
          best_available_rule_key: best&.rule_key,
          missing_evidence: missing_evidence(best, actual, aian_verified: aian_verified, basis: basis),
          state_share_delta_cents: delta_cents(actual, best, billed_amount_cents)
        )
      end

      # Classify and persist the determination as the audit artifact.
      def classify!(encounter_identifier:, person_identifier: nil, facility_identifier: nil,
                    evidence_refs: [], claim_reference: nil, **classify_opts)
        result = classify(**classify_opts)

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
          claim_reference: claim_reference,
          determined_at: Time.current
        )
      end

      private

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

      def missing_evidence(best, actual, aian_verified:, basis:)
        return [] if best.nil? || best == actual

        missing = []
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
