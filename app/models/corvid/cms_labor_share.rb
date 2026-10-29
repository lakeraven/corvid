# frozen_string_literal: true

module Corvid
  # Labor-related share CMS applies the wage index to, by payment system
  # and calendar year. Reference data like the other CMS rate tables —
  # not tenant-scoped. OPPS and ASC price calendar year N with this
  # year's share and the fiscal year N IPPS wage index.
  #
  # A missing row is undetermined. Callers must not substitute 1.
  class CmsLaborShare < ::ActiveRecord::Base
    self.table_name = "corvid_cms_labor_shares"

    PAYMENT_SYSTEMS = %w[opps asc].freeze

    validates :payment_system, presence: true, inclusion: { in: PAYMENT_SYSTEMS }
    validates :calendar_year, presence: true, uniqueness: { scope: :payment_system }
    validates :labor_share, presence: true, numericality: { greater_than: 0, less_than: 1 }
    validates :source, presence: true

    def self.lookup(payment_system:, calendar_year:)
      find_by(payment_system: payment_system.to_s, calendar_year: calendar_year)
    end

    # An identical re-seed of the same (payment_system, calendar_year)
    # snapshot returns the row already stored. A second row with a
    # different share, source, or label is still invalid.
    def self.create!(attributes = nil, &block)
      existing = identical_row(attributes)
      return existing if existing

      super
    end

    def self.identical_row(attributes)
      attrs = attributes.respond_to?(:symbolize_keys) ? attributes.symbolize_keys : {}
      return if attrs[:payment_system].blank? || attrs[:calendar_year].blank?

      row = find_by(payment_system: attrs[:payment_system].to_s, calendar_year: attrs[:calendar_year])
      return unless row
      return unless row.source == attrs[:source].to_s
      return unless row.release_label.to_s == attrs[:release_label].to_s
      return if attrs[:labor_share].nil?
      return unless row.labor_share == BigDecimal(attrs[:labor_share].to_s)

      row
    end
    private_class_method :identical_row

    # amount × (labor_share × wage_index + (1 − labor_share)), rounded
    # to cents once. amount is weight × conversion factor, still unrounded.
    # Inputs are BigDecimal (ADR 0004); this does not coerce through Float.
    def self.wage_adjusted_amount(amount, wage_index:, labor_share:)
      share = labor_share
      factor = (share * wage_index) + (BigDecimal("1") - share)
      (amount * factor).round(2)
    end
  end
end
