# frozen_string_literal: true

require "date"

require_relative "claim"
require_relative "scrub_checks"
require_relative "scrub_ruleset"

module Corvid
  module Rcm
    # One thing wrong with one claim, in words a biller can act on.
    ScrubFinding = Data.define(
      :rule_id, :category, :severity, :message, :remedy,
      :claim_identifier, :line_sequence, :ruleset_version
    ) do
      def blocking?
        severity == :block
      end

      def to_s
        location = line_sequence ? " [line #{line_sequence}]" : ""
        "#{severity.to_s.upcase} #{rule_id}#{location}: #{message}#{remedy ? " #{remedy}" : ''}"
      end
    end

    # The verdict on one claim.
    ScrubResult = Data.define(:claim_identifier, :ruleset_version, :evaluated_as_of, :findings) do
      def blocking_findings
        findings.select(&:blocking?)
      end

      def warnings
        findings.reject(&:blocking?)
      end

      # Whether the claim may be transmitted. Warnings do not stop a claim;
      # blocks do.
      def submittable?
        blocking_findings.empty?
      end

      def clean?
        findings.empty?
      end

      def blocked_by
        blocking_findings.map(&:rule_id)
      end
    end

    # Context a check may need beyond the claim itself.
    #
    # `as_of` is the date the rules are evaluated on — normally today for a
    # claim about to go out, but explicitly settable so a claim can be re-judged
    # by the rules that were in force on its date of service.
    #
    # `history` is the caller's view of prior services. Phase 0 has no database:
    # the caller supplies what it knows and the scrubber queries nothing.
    ScrubContext = Data.define(:as_of, :history) do
      def initialize(as_of: Date.today, history: nil)
        super
      end
    end

    # Evaluates a versioned ruleset against a claim-shaped input.
    #
    # The scrubber knows nothing about any specific rule: it resolves each
    # rule's `check` against `ScrubChecks` and turns whatever comes back into
    # findings. Adding a rule that reuses an existing check is a data-only
    # change.
    class Scrubber
      class UnknownCheck < StandardError; end

      def initialize(ruleset: ScrubRuleset.default, checks: ScrubChecks)
        @ruleset = ruleset
        @checks = checks
      end

      attr_reader :ruleset

      # @param claim [Corvid::Rcm::Claim]
      # @param as_of [Date] the date to evaluate rule effective windows on
      # @param history [Corvid::Rcm::ClaimHistory, nil] prior services the
      #   caller knows about, for the duplicate and repeat-service rules
      # @return [ScrubResult]
      def scrub(claim, as_of: Date.today, history: nil)
        context = ScrubContext.new(as_of: as_of, history: history)
        findings = @ruleset.effective_on(as_of).flat_map { |rule| apply(rule, claim, context) }

        ScrubResult.new(
          claim_identifier: claim.identifier,
          ruleset_version: @ruleset.version,
          evaluated_as_of: as_of,
          findings: findings
        )
      end

      private

      def apply(rule, claim, context)
        unless @checks.respond_to?(rule.check)
          raise UnknownCheck, "rule #{rule.id} names check #{rule.check}, which is not implemented"
        end

        @checks.public_send(rule.check, claim, rule.params, context).map do |failure|
          values = failure[:values] || {}
          ScrubFinding.new(
            rule_id: rule.id,
            category: rule.category,
            severity: rule.severity,
            message: interpolate(rule.message, values),
            remedy: rule.remedy && interpolate(rule.remedy, values),
            claim_identifier: claim.identifier,
            line_sequence: failure[:line_sequence],
            ruleset_version: @ruleset.version
          )
        end
      end

      # `format` would raise on a message whose placeholders and values drift
      # apart. A rule with a stale placeholder should still deliver a usable
      # message rather than take the whole scrub down, so unresolved
      # placeholders are left visible instead.
      def interpolate(template, values)
        template.to_s.gsub(/%\{(\w+)\}/) do
          key = Regexp.last_match(1).to_sym
          values.key?(key) ? values[key].to_s : "%{#{key}}"
        end
      end
    end
  end
end
