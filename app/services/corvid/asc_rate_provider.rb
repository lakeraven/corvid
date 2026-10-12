# frozen_string_literal: true

module Corvid
  # Real ASC payment rate provider (#278). CMS publishes ASC payment
  # data per HCPCS (Addendum AA), not per APC — different structure
  # from OPPS. The formula matches OPPS in shape:
  #
  #   medicare_equivalent = payment_weight × ASC_conversion_factor × wage_index
  #
  # but the lookup is keyed by HCPCS. For an HCPCS that's both
  # OPPS-paid and ASC-paid, ASC typically yields a lower rate
  # (smaller CF, sometimes smaller weight).
  #
  # Calendar-year boundaries (Jan 1), matching OPPS.
  #
  # Wage index (#369): sourced from `Corvid::IppsHospitalRate` rather
  # than `AscConversionFactor#wage_index` — see OppsRateProvider's
  # docstring for the full rationale (shared wage-area data, FY-keyed
  # lookup, NATIONAL/1.0 fallback chain). Mirrors that provider exactly.
  module AscRateProvider
    SOURCE = :asc_real

    Lookup = Struct.new(:rate, :release_label, keyword_init: true)

    class << self
      def rate_for(hcpcs_code:, locality: nil, date: nil)
        result = lookup_for(hcpcs_code: hcpcs_code, locality: locality, date: date)
        result&.rate
      end

      def lookup_for(hcpcs_code:, locality: nil, date: nil)
        return nil if hcpcs_code.nil? || date.nil?

        normalized_locality = locality.to_s.strip.empty? ? AscConversionFactor::NATIONAL_LOCALITY : locality

        cy = calendar_year(date)
        rate_row = AscHcpcsRate.find_by(hcpcs_code: hcpcs_code.to_s, calendar_year: cy)
        return nil unless rate_row

        cf_row = AscConversionFactor.lookup(calendar_year: cy, locality: normalized_locality)
        return nil unless cf_row

        wage_row = IppsHospitalRate.lookup(fiscal_year: federal_fiscal_year(date), locality: normalized_locality)
        wage_index = wage_row&.wage_index || BigDecimal("1.0")

        rate = (rate_row.payment_weight * cf_row.conversion_factor * wage_index).round(2)
        label = [ rate_row.release_label, cf_row.release_label, wage_row&.release_label ]
                  .compact.find { |l| l.to_s.start_with?("stub") } ||
                rate_row.release_label || cf_row.release_label
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
