# frozen_string_literal: true

module Corvid
  # Real OPPS APC rate provider (#277). Returns the OPPS payment
  # estimate for a single hospital outpatient encounter:
  #
  #   medicare_equivalent = apc_relative_weight × conversion_factor × wage_index
  #
  # Sourced from CMS OPPS Final Rule tables (Addendum A/B) loaded into
  # corvid_opps_apc_weights and corvid_opps_conversion_factors. When
  # data for the (year, APC, locality) tuple is missing, returns nil —
  # the analyzer falls back to OppsStubRateProvider in that case so an
  # obligation still gets a directional dollar figure at :stub_estimate
  # confidence.
  #
  # OPPS uses **calendar year** boundaries (Jan 1) — not federal fiscal
  # year. Different from IPPS.
  module OppsRateProvider
    SOURCE = :opps_real

    Lookup = Struct.new(:rate, :release_label, keyword_init: true)

    class << self
      def rate_for(apc_code:, locality: nil, date: nil)
        result = lookup_for(apc_code: apc_code, locality: locality, date: date)
        result&.rate
      end

      def lookup_for(apc_code:, locality: nil, date: nil)
        return nil if apc_code.nil? || date.nil?

        # Normalize nil/blank locality to NATIONAL at the provider
        # boundary so the downstream IN-list never contains NULL —
        # PG's `IN (NULL, 'NATIONAL')` behavior is surprising
        # (matches NATIONAL only because NULL never equals anything,
        # but easy to misread). Treating blank as "unknown facility,
        # use the national default" matches operator intent.
        normalized_locality = locality.to_s.strip.empty? ? OppsConversionFactor::NATIONAL_LOCALITY : locality

        cy = calendar_year(date)
        weight_row = OppsApcWeight.find_by(apc_code: apc_code.to_s, calendar_year: cy)
        return nil unless weight_row

        cf_row = OppsConversionFactor.lookup(calendar_year: cy, locality: normalized_locality)
        return nil unless cf_row

        rate = (weight_row.relative_weight * cf_row.conversion_factor * cf_row.wage_index).round(2)
        # Take the more conservative label: if either row is stub-derived,
        # the resulting rate is stub-derived.
        label = [ weight_row.release_label, cf_row.release_label ]
                  .compact.find { |l| l.to_s.start_with?("stub") } ||
                weight_row.release_label || cf_row.release_label
        Lookup.new(rate: rate, release_label: label)
      end

      def source
        SOURCE
      end

      private

      def calendar_year(date)
        date.respond_to?(:year) ? date.year : date.to_i
      end
    end
  end
end
