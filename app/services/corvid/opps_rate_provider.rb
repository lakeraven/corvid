# frozen_string_literal: true

module Corvid
  # Real OPPS APC rate provider (#277, #722). Returns the OPPS payment
  # estimate for a single hospital outpatient encounter:
  #
  #   medicare_equivalent =
  #     apc_relative_weight × conversion_factor
  #       × (labor_share × wage_index + (1 − labor_share))
  #
  # CMS applies the wage index only to the labor-related share. The
  # share is a sourced row in corvid_cms_labor_shares for that calendar
  # year, not a constant. A year with no labor-share row is undetermined:
  # lookup_for returns nil and never prices the wage index at 100% labor.
  # Money is exact BigDecimal arithmetic, rounded to cents once at the
  # end (ADR 0004).
  #
  # Sourced from CMS OPPS Final Rule tables (Addendum A/B) loaded into
  # corvid_opps_apc_weights and corvid_opps_conversion_factors. When
  # data for the (year, APC, locality) tuple is missing, returns nil —
  # the analyzer falls back to OppsStubRateProvider in that case so an
  # obligation still gets a directional dollar figure at :stub_estimate
  # confidence.
  #
  # OPPS weights and conversion factors use **calendar year** boundaries
  # (Jan 1) — not federal fiscal year. Different from IPPS.
  #
  # Wage index (#369, #722): sourced from `Corvid::IppsHospitalRate`
  # rather than `OppsConversionFactor#wage_index` — the wage-area (CBSA)
  # wage index is a single CMS-published figure shared across
  # IPPS/OPPS/ASC. CMS prices calendar year N with the fiscal year N
  # IPPS wage index. FY N starts 1 Oct of N−1, so this is the fiscal
  # year numbered the same as the calendar year, not the fiscal year of
  # the service date. An October–December CY N service uses FY N, not
  # FY N+1. Falls back to the IPPS NATIONAL row when no CBSA-specific
  # row is loaded, then to 1.0 when no IPPS wage data is loaded at all.
  # When a wage-index row is used, the lookup records that row's fiscal
  # year and the labor share. When no row is loaded and the index
  # defaults to 1.0, `wage_index_fiscal_year` is nil. The price is the
  # same either way.
  module OppsRateProvider
    SOURCE = :opps_real

    Lookup = Struct.new(
      :rate, :release_label, :wage_index_fiscal_year, :labor_share,
      keyword_init: true
    )

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
        # CMS prices CY N with FY N. FY N is not the service date's own
        # fiscal year: Oct–Dec of CY N stays on FY N.
        cy = calendar_year(date)
        locality_code = normalized_locality(locality)
        weight_row = OppsApcWeight.find_by(apc_code: apc_code.to_s, calendar_year: cy)
        return nil unless weight_row

        cf_row = OppsConversionFactor.lookup(calendar_year: cy, locality: locality_code)
        return nil unless cf_row

        labor_row = CmsLaborShare.lookup(payment_system: "opps", calendar_year: cy)
        return nil unless labor_row

        wage_row = IppsHospitalRate.lookup(fiscal_year: cy, locality: locality_code)
        wage_index = wage_row&.wage_index || BigDecimal("1.0")
        Lookup.new(
          rate: CmsLaborShare.wage_adjusted_amount(
            weight_row.relative_weight * cf_row.conversion_factor,
            wage_index: wage_index,
            labor_share: labor_row.labor_share
          ),
          # Take the more conservative label: if any of the three rate
          # rows is stub-derived, the resulting rate is stub-derived.
          # The labor-share row is not part of that label — a missing
          # share already returned nil above.
          release_label: conservative_release_label(weight_row, cf_row, wage_row),
          wage_index_fiscal_year: wage_row&.fiscal_year,
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
        locality.to_s.strip.empty? ? OppsConversionFactor::NATIONAL_LOCALITY : locality
      end

      def conservative_release_label(weight_row, cf_row, wage_row)
        [ weight_row.release_label, cf_row.release_label, wage_row&.release_label ]
          .compact.find { |label| label.to_s.start_with?("stub") } ||
          weight_row.release_label.presence || cf_row.release_label.presence
      end
    end
  end
end
