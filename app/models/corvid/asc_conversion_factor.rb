# frozen_string_literal: true

module Corvid
  # CMS ASC conversion factor and wage index, by calendar year and
  # locality. Locality "NATIONAL" is the fallback row used when no
  # locality-specific rate is loaded. The ASC CF runs roughly 60% of
  # the OPPS CF — same APC × less money.
  class AscConversionFactor < ::ActiveRecord::Base
    self.table_name = "corvid_asc_conversion_factors"

    NATIONAL_LOCALITY = "NATIONAL"

    validates :calendar_year, presence: true
    validates :locality, presence: true
    validates :conversion_factor, presence: true, numericality: { greater_than: 0 }
    validates :wage_index, presence: true, numericality: { greater_than: 0 }

    # Same pattern as OppsConversionFactor.lookup: single round-trip,
    # prefer the locality-specific row when both exist.
    def self.lookup(calendar_year:, locality:)
      rows = where(calendar_year: calendar_year, locality: [ locality, NATIONAL_LOCALITY ])
               .index_by(&:locality)
      rows[locality] || rows[NATIONAL_LOCALITY]
    end
  end
end
