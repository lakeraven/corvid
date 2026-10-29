# frozen_string_literal: true

module Corvid
  # Real ASC payment rate provider (#278, #722). CMS publishes ASC
  # payment data per HCPCS (Addendum AA), not per APC — different
  # structure from OPPS. The formula matches OPPS in shape:
  #
  #   medicare_equivalent =
  #     payment_weight × ASC_conversion_factor
  #       × (labor_share × wage_index + (1 − labor_share))
  #
  # but the lookup is keyed by HCPCS. For an HCPCS that's both
  # OPPS-paid and ASC-paid, ASC typically yields a lower rate
  # (smaller CF, sometimes smaller weight). The labor-related share
  # is the ASC row in corvid_cms_labor_shares for that calendar year
  # (50% in the shipped final-rule file), not a constant. No row for
  # the year is undetermined: lookup_for returns nil and never prices
  # at a 100% labor share. Money is exact BigDecimal, rounded to cents
  # once at the end (ADR 0004).
  #
  # Weights and the conversion factor use calendar-year boundaries
  # (Jan 1), matching OPPS.
  #
  # Wage index (#369, #722): sourced from `Corvid::IppsHospitalRate`
  # rather than `AscConversionFactor#wage_index`. CMS prices calendar
  # year N with the fiscal year N IPPS wage index (FY N starts 1 Oct
  # of N−1) — not the service date's own fiscal year. See
  # OppsRateProvider for the shared wage-area rationale and the
  # NATIONAL / 1.0 fallback. The lookup records the wage-index fiscal
  # year and the labor share used. The release label stays the
  # conservative label of the HCPCS, conversion-factor, and wage-index
  # rows, as before.
  module AscRateProvider
    SOURCE = :asc_real

    Lookup = Struct.new(
      :rate, :release_label, :wage_index_fiscal_year, :labor_share,
      keyword_init: true
    )

    class << self
      def rate_for(hcpcs_code:, locality: nil, date: nil)
        result = lookup_for(hcpcs_code: hcpcs_code, locality: locality, date: date)
        result&.rate
      end

      def lookup_for(hcpcs_code:, locality: nil, date: nil)
        return nil if hcpcs_code.nil? || date.nil?

        # CMS prices CY N with FY N. Oct–Dec of CY N stays on FY N,
        # not FY N+1. Weight and CF stay on the calendar year.
        cy = calendar_year(date)
        locality_code = normalized_locality(locality)
        rate_row = AscHcpcsRate.find_by(hcpcs_code: hcpcs_code.to_s, calendar_year: cy)
        return nil unless rate_row

        cf_row = AscConversionFactor.lookup(calendar_year: cy, locality: locality_code)
        return nil unless cf_row

        labor_row = CmsLaborShare.lookup(payment_system: "asc", calendar_year: cy)
        return nil unless labor_row

        wage_row = IppsHospitalRate.lookup(fiscal_year: cy, locality: locality_code)
        wage_index = wage_row&.wage_index || BigDecimal("1.0")
        Lookup.new(
          rate: CmsLaborShare.wage_adjusted_amount(
            rate_row.payment_weight * cf_row.conversion_factor,
            wage_index: wage_index,
            labor_share: labor_row.labor_share
          ),
          release_label: conservative_release_label(rate_row, cf_row, wage_row),
          wage_index_fiscal_year: cy,
          labor_share: labor_row.labor_share
        )
      end

      def source
        SOURCE
      end

      private

      def calendar_year(date)
        date.respond_to?(:year) ? date.year : date.to_i
      end

      def normalized_locality(locality)
        locality.to_s.strip.empty? ? AscConversionFactor::NATIONAL_LOCALITY : locality
      end

      def conservative_release_label(rate_row, cf_row, wage_row)
        [ rate_row.release_label, cf_row.release_label, wage_row&.release_label ]
          .compact.find { |label| label.to_s.start_with?("stub") } ||
          rate_row.release_label.presence || cf_row.release_label.presence
      end
    end
  end
end
