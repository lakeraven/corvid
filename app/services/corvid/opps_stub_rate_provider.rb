# frozen_string_literal: true

module Corvid
  # Phase 1.5 placeholder for hospital outpatient MLR repricing. Returns
  # rough national-average OPPS payment estimates by year, optionally
  # adjusted by APC if known. Replace at the `OppsRateProvider` facade
  # once #277 lands.
  #
  # Methodology: per-year national-average OPPS payment per claim line.
  # Outpatient encounters bundle multiple lines, so a stub for a single
  # OPPS-paid encounter is a per-encounter approximation, not per-APC.
  module OppsStubRateProvider
    # Approximate national-average OPPS payment per outpatient encounter
    # by year. Wide variance in reality — this is rough.
    NATIONAL_AVERAGE_BY_YEAR = {
      2007 =>   650, 2008 =>   700, 2009 =>   750, 2010 =>   800,
      2011 =>   850, 2012 =>   900, 2013 =>   950, 2014 => 1_000,
      2015 => 1_050, 2016 => 1_100, 2017 => 1_150, 2018 => 1_200,
      2019 => 1_250, 2020 => 1_300, 2021 => 1_350, 2022 => 1_400,
      2023 => 1_450, 2024 => 1_500, 2025 => 1_550, 2026 => 1_600
    }.freeze

    DEFAULT_NATIONAL_AVERAGE = 1_600

    class << self
      def rate_for(apc_code: nil, locality: nil, date: nil)
        return nil if date.nil?

        year = date.respond_to?(:year) ? date.year : date.to_i
        NATIONAL_AVERAGE_BY_YEAR[year] || DEFAULT_NATIONAL_AVERAGE
      end

      def source = :stub
    end
  end
end
