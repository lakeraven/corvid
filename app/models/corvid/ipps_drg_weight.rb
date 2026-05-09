# frozen_string_literal: true

module Corvid
  # CMS IPPS DRG relative weights, by federal fiscal year. The product
  # weight × hospital base rate × wage index is the IPPS payment
  # estimate for a single discharge under that DRG. Sourced from the
  # CMS IPPS Final Rule tables published annually.
  class IppsDrgWeight < ::ActiveRecord::Base
    self.table_name = "corvid_ipps_drg_weights"

    validates :fiscal_year, presence: true
    validates :drg_code, presence: true
    validates :relative_weight, presence: true, numericality: { greater_than: 0 }

    scope :for_year, ->(year) { where(fiscal_year: year) }

    def self.weight_for(drg_code:, fiscal_year:)
      find_by(drg_code: drg_code.to_s, fiscal_year: fiscal_year)&.relative_weight
    end
  end
end
