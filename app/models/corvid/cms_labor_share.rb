# frozen_string_literal: true

module Corvid
  # Labor-related share CMS applies the wage index to, by payment system
  # and calendar year. Reference data like the other CMS rate tables —
  # not tenant-scoped. OPPS and ASC price calendar year N with this
  # year's share and the fiscal year N IPPS wage index.
  #
  # A missing row is undetermined. Callers must not substitute 1.
  # labor_share is numeric(5,4): at most four decimal places. The column
  # type rounds on assignment, so validation reads the value the caller
  # assigned and rejects a share that would not survive that rounding.
  # A rejected share is not stored.
  class CmsLaborShare < ::ActiveRecord::Base
    self.table_name = "corvid_cms_labor_shares"

    PAYMENT_SYSTEMS = %w[opps asc].freeze
    MAX_DECIMAL_PLACES = 4

    validates :payment_system, presence: true, inclusion: { in: PAYMENT_SYSTEMS }
    validates :calendar_year, presence: true, uniqueness: { scope: :payment_system }
    validates :labor_share, presence: true, numericality: { greater_than: 0, less_than: 1 }
    validate :labor_share_decimal_places
    validates :source, presence: true

    def self.lookup(payment_system:, calendar_year:)
      find_by(payment_system: payment_system.to_s, calendar_year: calendar_year)
    end

    # amount × (labor_share × wage_index + (1 − labor_share)), rounded
    # to cents once. amount is weight × conversion factor, still unrounded.
    # Inputs are BigDecimal (ADR 0004); this does not coerce through Float.
    def self.wage_adjusted_amount(amount, wage_index:, labor_share:)
      share = labor_share
      factor = (share * wage_index) + (BigDecimal("1") - share)
      (amount * factor).round(2)
    end

    private

    def labor_share_decimal_places
      decimal = decimal_from(labor_share_before_type_cast)
      return if decimal.nil? || !decimal.finite?
      return if decimal == decimal.round(MAX_DECIMAL_PLACES)

      errors.add(:labor_share, "must have at most four decimal places")
    end

    def decimal_from(raw)
      case raw
      when nil, ""
        nil
      when BigDecimal
        raw
      when String
        text = raw.strip
        text.empty? ? nil : BigDecimal(text)
      when Numeric
        BigDecimal(raw.to_s)
      end
    rescue ArgumentError
      nil
    end
  end
end
