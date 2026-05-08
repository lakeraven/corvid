# frozen_string_literal: true

module Corvid
  # Phase 1.5 placeholder for inpatient hospital MLR repricing. Returns
  # rough national-average IPPS payment estimates by DRG and year.
  #
  # **NOT a citation-ready rate.** This is a directional estimate so the
  # analyzer can produce a dollar number for hospital obligations while the
  # real IPPS DRG rate ingestion (#276) is in flight. Replace at the
  # `IppsRateProvider` facade once #276 lands.
  #
  # Methodology: hardcoded national-average per-discharge IPPS payment by
  # **federal fiscal year** (Oct 1 – Sep 30; from public CMS aggregate IPPS
  # data) multiplied by a per-DRG relative-weight factor. Service dates
  # are converted to FY before lookup. Locality wage index is intentionally
  # not applied — that level of accuracy waits for #276.
  module IppsStubRateProvider
    # National-average per-discharge IPPS payment by federal fiscal year.
    # Approximated from CMS aggregate published statistics.
    NATIONAL_AVERAGE_BY_YEAR = {
      2007 =>  9_200, 2008 =>  9_500, 2009 =>  9_800, 2010 => 10_200,
      2011 => 10_500, 2012 => 10_800, 2013 => 11_000, 2014 => 11_300,
      2015 => 11_600, 2016 => 11_900, 2017 => 12_200, 2018 => 12_500,
      2019 => 12_800, 2020 => 13_100, 2021 => 13_400, 2022 => 13_700,
      2023 => 14_000, 2024 => 14_300, 2025 => 14_600, 2026 => 14_900
    }.freeze

    DEFAULT_NATIONAL_AVERAGE = 14_900 # for years outside the table

    # DRG-specific multiplier vs. national-average. Approximate; covers
    # the DRGs registered in PrcProcedureDictionary defaults plus a few
    # high-frequency PRC procedures. Unknown DRGs use 1.0 (national avg).
    DRG_MULTIPLIERS = {
      "470" => 1.00, # Major joint replacement w/o complications
      "469" => 1.55, # Major joint replacement w/ complications
      "287" => 0.65, # Diagnostic cardiac cath
      "236" => 2.75, # CABG, 3+ vessel w/o complications
      "338" => 0.75, # Open appendectomy
      "418" => 1.00, # Laparoscopic cholecystectomy
      "871" => 0.95, # Septicemia w/o vent w/ MCC
      "872" => 0.65, # Septicemia w/o vent w/o MCC
      "291" => 0.85, # Heart failure w/ MCC
      "292" => 0.65  # Heart failure w/ CC
    }.freeze

    DEFAULT_DRG_MULTIPLIER = 1.0

    class << self
      # Returns the stub IPPS rate as a Float, or nil if inputs are unusable.
      # Locality is accepted for interface compatibility with the eventual
      # real IPPS lookup but ignored by the stub.
      #
      # Service date is converted to federal fiscal year for the rate
      # lookup — IPPS rates change on Oct 1, not Jan 1. A Nov 15 2024
      # discharge bills against the FY 2025 rate, not FY 2024.
      def rate_for(drg_code:, locality: nil, date: nil)
        return nil if drg_code.nil? || date.nil?

        fy = federal_fiscal_year(date)
        national_avg = NATIONAL_AVERAGE_BY_YEAR[fy] || DEFAULT_NATIONAL_AVERAGE
        multiplier = DRG_MULTIPLIERS[drg_code.to_s] || DEFAULT_DRG_MULTIPLIER

        (national_avg * multiplier).round(2)
      end

      # Always :stub during Phase 1.5. The IppsRateProvider facade in the
      # production path will return :real when #276 ingestion is available
      # for the requested year/locality.
      def source = :stub

      private

      # Federal fiscal year for IPPS rate lookup. CMS IPPS rates change
      # Oct 1; service dates from Oct 1 onward use the *next* calendar
      # year as the FY. Service dates Jan 1–Sep 30 use the current year.
      def federal_fiscal_year(date)
        date.month >= 10 ? date.year + 1 : date.year
      end
    end
  end
end
