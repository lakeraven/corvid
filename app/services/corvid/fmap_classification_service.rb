# frozen_string_literal: true

module Corvid
  # Deterministic FMAP classification (#546). Applies the FmapRules in
  # force on the encounter's date of service — never today's rules — and
  # reports, alongside the evidence-supported category, the best category
  # available had all evidence been present, plus what is missing. No
  # silent inference: an unevidenced 100% is reported as a gap with the
  # missing evidence named, never granted, and an encounter no in-force
  # rule covers comes back UNDETERMINED with a reason — never a
  # definitive category a CMS-64 run would read as settled. The
  # expansion tier additionally requires StateMedicaidRules.lookup to
  # show a configured expansion state; otherwise the result is
  # undetermined, not regular FMAP, and regular FMAP is not reported
  # as the best available tier for that refusal.
  class FmapClassificationService
    UNDETERMINED = "undetermined"

    # Reasons a result carries no applied rule, or carries a lower one
    # than the inputs superficially suggest. Persisted with the
    # determination so an audit sees why, not just what.
    NO_RULES_IN_FORCE = "no_rules_in_force"
    NO_MATCHING_RULE = "no_matching_rule"
    UNEVIDENCED_100 = "unevidenced_100_percent"
    # The 90% tier matched, but the jurisdiction is not a configured
    # expansion state. Undetermined — never a silent drop to regular FMAP.
    EXPANSION_STATE_NOT_CONFIGURED = "expansion_state_not_configured"
    REASONS = [ NO_RULES_IN_FORCE, NO_MATCHING_RULE, UNEVIDENCED_100, EXPANSION_STATE_NOT_CONFIGURED ].freeze

    # Raised by classify! when the encounter already has a current
    # determination: correct it with FmapDetermination#supersede_with!.
    class AlreadyDeterminedError < StandardError; end

    # Accepted coverage groups: main's eligibility-group vocabulary, plus
    # "unknown", which matches no group-scoped rule.
    COVERAGE_GROUPS = (StateMedicaidRules::GROUPS + %w[unknown]).freeze

    Result = Struct.new(
      :category, :fmap_percent, :rule_key, :rule_citations,
      :best_available_category, :best_available_rule_key, :missing_evidence,
      :state_share_delta_cents, :determination_reason,
      :received_through_basis, :facility_authority, :evidence_refs,
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
        # The jurisdiction selects the state's rows; without one, federal
        # rows alone would read as a complete answer.
        raise ArgumentError, "jurisdiction is required" if jurisdiction.to_s.strip.empty?
        check_coverage_group!(coverage_group)
        if received_through_basis.present? && !FmapRule::RECEIVED_THROUGH_BASES.include?(received_through_basis.to_s)
          raise ArgumentError, "received_through_basis is not recognized"
        end
        authority = stored_authority(facility_authority)
        authority = nil unless authority&.in_force_on?(date_of_service)
        authority_type = authority&.authority_type
        basis = received_through_basis.presence || (authority_type ? "facility_authority" : nil)
        evidence = caller_evidence(evidence_refs)
        backed = authority.present? && basis == "facility_authority"
        context = { authority: authority, basis: basis, evidence: evidence }

        rules = FmapRule.in_force_on(date_of_service).for_jurisdiction(jurisdiction).to_a

        # An unloaded (or wholly end-dated) rule set is a broken input,
        # not a finding of "not Medicaid". Say so loudly and refuse.
        if rules.empty?
          warn_no_rules(date_of_service, jurisdiction)
          return undetermined_result(NO_RULES_IN_FORCE, **context)
        end

        # Separate registries. The expansion tier still matches on its
        # coverage group; StateMedicaidRules.lookup says whether this
        # jurisdiction may use it. Lookup canonicalizes case.
        expansion_open = expansion_state?(jurisdiction)

        matched = best_match(rules, authority_type: authority_type, aian_verified: aian_verified,
                                    basis: basis, coverage_group: coverage_group)
        best = best_match(lens_rules(rules, expansion_open), authority_type: authority_type, aian_verified: true,
                                                             basis: basis, coverage_group: coverage_group)

        # The 100 percent tiers are the ones that move federal dollars,
        # so each of their requirements must rest on its own evidence.
        # Without it, fall back to the highest *evidenced* tier the same
        # inputs support, or refuse — never grant. The fallback is gated
        # below: a 90 percent expansion tier in a non-expansion state is
        # not that evidenced tier.
        actual = matched
        reason = nil
        if matched&.hundred_percent? &&
           matched.unmet_evidence(received_through_basis: basis, evidence: evidence, authority_backed: backed).any?
          reason = UNEVIDENCED_100
          actual = best_match(rules.reject(&:hundred_percent?), authority_type: authority_type,
                              aian_verified: aian_verified, basis: basis, coverage_group: coverage_group)
        end

        # The tier we are about to refuse, so the lens can keep a higher
        # tier more evidence could reach and drop a lower one. The gate
        # itself clears the applied rule.
        refused_expansion = actual if !expansion_open && actual&.expansion?
        actual, reason = gate_expansion_tier(actual, reason, expansion_open)
        best = best_after_expansion_refusal(best, refused_expansion, reason)

        missing = missing_evidence(best, actual, aian_verified: aian_verified, basis: basis,
                                                 evidence: evidence, backed: backed, reason: reason)

        if actual.nil?
          return undetermined_result(reason || NO_MATCHING_RULE, best: best, missing: missing, **context)
        end

        Result.new(
          category: actual.category,
          fmap_percent: actual.fmap_percent,
          rule_key: actual.rule_key,
          rule_citations: [ actual.statutory_citation ],
          best_available_category: best&.category,
          best_available_rule_key: best&.rule_key,
          missing_evidence: missing,
          state_share_delta_cents: delta_cents(actual, best, billed_amount_cents),
          determination_reason: reason,
          received_through_basis: basis,
          facility_authority: authority,
          evidence_refs: evidence
        )
      end

      # Classify and persist the determination as the audit artifact.
      # The evidence refs are both the classification input (a 100
      # percent tier is unreachable without them) and the persisted
      # chain the determination rests on, together with the authority
      # and basis classification used.
      def classify!(encounter_identifier:, person_identifier: nil, facility_identifier: nil,
                    evidence_refs: [], claim_reference: nil, **classify_opts)
        authority = stored_authority(classify_opts[:facility_authority])
        if authority && facility_identifier.present? && authority.facility_identifier != facility_identifier
          raise ArgumentError, "facility authority belongs to a different facility than the encounter"
        end

        if FmapDetermination.current.for_encounter(encounter_identifier).exists?
          raise AlreadyDeterminedError, "encounter already has a current FMAP determination; supersede it instead"
        end

        result = classify(evidence_refs: evidence_refs, **classify_opts)
        applied = result.facility_authority

        FmapDetermination.create!(
          encounter_identifier: encounter_identifier,
          person_identifier: person_identifier,
          facility_identifier: facility_identifier.presence || authority&.facility_identifier,
          date_of_service: classify_opts.fetch(:date_of_service),
          jurisdiction: classify_opts.fetch(:jurisdiction),
          category: result.category,
          fmap_percent: result.fmap_percent,
          rule_key: result.rule_key,
          rule_citations: result.rule_citations,
          evidence_refs: result.evidence_refs,
          aian_verified: classify_opts.fetch(:aian_verified, false),
          received_through_basis: result.received_through_basis,
          facility_authority_id: applied&.id,
          authority_type: applied&.authority_type,
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

      # A jurisdiction may use an expansion tier only when the registry
      # has it configured and expanded. Shared with FmapDetermination.
      # Read-only lookup: the registry is not written. configured? first,
      # because an unregistered code is NotConfigured and has no expansion
      # flag to assume. Fail closed.
      def expansion_state?(jurisdiction)
        entry = StateMedicaidRules.lookup(jurisdiction)
        entry.configured? && entry.expanded? == true
      end

      private

      # A refusal, not a category: no percent, no rule, no citation. The
      # best-available lens still reports what full evidence would have
      # reached, so the gap is visible rather than silently absent.
      def undetermined_result(reason, best: nil, missing: [], authority: nil, basis: nil, evidence: [])
        Result.new(
          category: UNDETERMINED,
          fmap_percent: nil,
          rule_key: nil,
          rule_citations: [],
          best_available_category: best&.category,
          best_available_rule_key: best&.rule_key,
          missing_evidence: missing,
          state_share_delta_cents: nil,
          determination_reason: reason,
          received_through_basis: basis,
          facility_authority: authority,
          evidence_refs: evidence
        )
      end

      def warn_no_rules(date_of_service, jurisdiction)
        return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.error(
          "[Corvid::FmapClassificationService] no FMAP rules in force for " \
          "jurisdiction=#{jurisdiction} date_of_service=#{date_of_service}; " \
          "classification refused (load rules with rake corvid:fmap:load_rules)"
        )
      end

      def check_coverage_group!(coverage_group)
        return if coverage_group.nil? || COVERAGE_GROUPS.include?(coverage_group.to_s)
        raise ArgumentError, "coverage_group is not recognized"
      end

      # The authority as stored for the current tenant. An unsaved record,
      # one from another tenant, or an in-memory edit never confers a basis.
      def stored_authority(facility_authority)
        return nil if facility_authority.nil?
        raise ArgumentError, "facility authority must be persisted" unless facility_authority.persisted?

        stored = FacilityAuthority.find_by(id: facility_authority.id)
        raise ArgumentError, "facility authority is not in the current tenant" if stored.nil?
        stored
      end

      # Callers supply only the kinds in FmapRule::CALLER_EVIDENCE_KINDS,
      # as typed entries; received-through rests on the stored authority.
      def caller_evidence(evidence_refs)
        entries = Array(evidence_refs)
        unless entries.all?(Hash)
          raise ArgumentError, "evidence_refs entries must be { supports:, ref: } hashes"
        end

        evidence = FmapRule.normalize_evidence(entries)
        if evidence.any? { |e| !FmapRule::CALLER_EVIDENCE_KINDS.include?(e["supports"]) }
          raise ArgumentError, "evidence_refs may only support #{FmapRule::CALLER_EVIDENCE_KINDS.join(', ')}"
        end
        evidence
      end

      # The best-available lens never names the expansion tier unless the
      # jurisdiction is a configured expansion state. reject copies; the
      # loaded rule rows are not mutated.
      def lens_rules(rules, expansion_open)
        return rules if expansion_open

        rules.reject(&:expansion?)
      end

      # The 90 tier is applied only in an expansion state. When it would
      # have been the result, refuse it — do not substitute regular FMAP.
      # An unevidenced 100 percent whose fallback is that tier stays
      # undetermined and keeps UNEVIDENCED_100, so the evidence gap stays
      # named; the fallback itself is not granted. A direct expansion
      # match is undetermined because the state is not configured as
      # expanded.
      def gate_expansion_tier(actual, reason, expansion_open)
        return [ actual, reason ] if expansion_open || !actual&.expansion?

        [ nil, reason || EXPANSION_STATE_NOT_CONFIGURED ]
      end

      # A refused expansion tier is not a misclassification down to a
      # lower tier. Keep a best-available rule only when it sits strictly
      # above the tier we refused (in practice a 100 percent tier more
      # evidence could reach). Otherwise leave the lens blank so
      # misclassification_gap? stays false. An unevidenced 100 percent
      # keeps its own lens: that refusal is a different reason.
      def best_after_expansion_refusal(best, refused, reason)
        return best unless reason == EXPANSION_STATE_NOT_CONFIGURED
        return nil if best.nil? || refused.nil? || best.expansion?
        return nil unless tier_above?(best, refused)

        best
      end

      # Fail closed when either percent is missing, unless the candidate
      # is a 100 percent tier and the refused rule is not: that tier is
      # above the expansion floor even if a percent was left unset.
      def tier_above?(candidate, floor)
        return false if candidate.nil? || floor.nil?

        high = candidate.fmap_percent
        low = floor.fmap_percent
        return high > low if !high.nil? && !low.nil?

        candidate.hundred_percent? && !floor.hundred_percent?
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

      # Every gap between the applied tier and the best-available one:
      # the asserted inputs that are absent and the evidence each of the
      # best rule's requirements still lacks.
      def missing_evidence(best, actual, aian_verified:, basis:, evidence:, backed:, reason:)
        missing = []
        missing << "evidence_refs" if reason == UNEVIDENCED_100 && evidence.empty?
        return missing if best.nil? || best == actual

        missing << "aian_attestation" if best.requires_aian && !aian_verified
        missing << "received_through_basis" if best.requires_received_through && basis.blank?
        missing.concat(best.unmet_evidence(received_through_basis: basis, evidence: evidence, authority_backed: backed))
        missing.uniq
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
