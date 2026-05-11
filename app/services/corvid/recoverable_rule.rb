# frozen_string_literal: true

module Corvid
  # Single source of truth for "what counts as a recoverable overpayment."
  # An obligation is recoverable iff its analysis was priced from real
  # CMS rate data — clear confidence AND real rate source.
  #
  # All council-facing artifacts (summary CSV, audit packet, demand
  # letter) gate dollar totals on this predicate. Stub-derived rows,
  # unmapped procedures/facilities, and rows with no rate for the
  # service year all show up in the "exceptions" backlog instead of
  # the recoverable total — they are operational signal, not citation-
  # ready demand-letter dollars.
  #
  # Rationale: a single mislabeled stub-derived row in a council
  # presentation creates a credibility hazard that's hard to walk
  # back. Better to over-route to the exceptions queue and let
  # operators force-include via an explicit forensic flag.
  module RecoverableRule
    RECOVERABLE_CONFIDENCE = "clear"
    RECOVERABLE_RATE_SOURCE = "real"

    class << self
      # Returns true iff the row (an AR record OR a detail-row hash
      # produced by PrcOverpaymentReportService) qualifies as
      # recoverable-now.
      def recoverable?(row)
        confidence = read_attr(row, :recovery_confidence)
        source = read_attr(row, :rate_source)
        confidence.to_s == RECOVERABLE_CONFIDENCE && source.to_s == RECOVERABLE_RATE_SOURCE
      end

      private

      def read_attr(row, key)
        if row.respond_to?(key)
          row.public_send(key)
        elsif row.is_a?(Hash)
          row[key] || row[key.to_s]
        end
      end
    end
  end
end
