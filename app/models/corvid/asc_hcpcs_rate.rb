# frozen_string_literal: true

module Corvid
  # CMS ASC payment weight per HCPCS code, by calendar year. Sourced
  # from the ASC payment system Final Rule Addendum AA. ASC pays per
  # HCPCS, not per APC — different structure from OPPS Addendum A
  # which is APC-keyed.
  #
  # `payment_indicator` carries the ASC PI code (e.g., G2, J8, R2, P2)
  # which the analyzer can use for future per-PI pricing logic. For
  # screening-estimate purposes today, any row with payment_weight > 0
  # is priced via the ASC formula: weight × ASC_CF × wage_index.
  class AscHcpcsRate < ::ActiveRecord::Base
    self.table_name = "corvid_asc_hcpcs_rates"

    validates :calendar_year, presence: true
    validates :hcpcs_code, presence: true
    validates :payment_weight, presence: true, numericality: { greater_than: 0 }

    scope :for_year, ->(year) { where(calendar_year: year) }
  end
end
