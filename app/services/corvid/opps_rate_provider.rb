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
  #
  # Wage index (#369): sourced from `Corvid::IppsHospitalRate` rather
  # than `OppsConversionFactor#wage_index` — the wage-area (CBSA) wage
  # index is a single CMS-published figure shared across IPPS/OPPS/ASC,
  # and IPPS is already the table that loads it. Looked up by the
  # service date's *federal fiscal year* (IPPS wage index turns over
  # Oct 1, not Jan 1 like the OPPS APC/CF table), so a rate can
  # combine a CY-keyed weight/CF row with an FY-keyed wage index row —
  # intentional; matches how CMS itself reconciles wage data across
  # the two payment systems. Falls back to the IPPS NATIONAL row when
  # no CBSA-specific row is loaded, then to 1.0 when no IPPS wage data
  # is loaded at all (today's default until #369's data backfill).
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

        wage_row = IppsHospitalRate.lookup(fiscal_year: federal_fiscal_year(date), locality: normalized_locality)
        wage_index = wage_row&.wage_index || BigDecimal("1.0")

        rate = (weight_row.relative_weight * cf_row.conversion_factor * wage_index).round(2)
        # Take the more conservative label: if any of the three rows
        # is stub-derived, the resulting rate is stub-derived.
        label = [ weight_row.release_label, cf_row.release_label, wage_row&.release_label ]
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

      # IPPS wage index changes Oct 1, not Jan 1 — mirrors
      # IppsRateProvider's private helper of the same name.
      def federal_fiscal_year(date)
        date.month >= 10 ? date.year + 1 : date.year
      end
    end
  end
end
