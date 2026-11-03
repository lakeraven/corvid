# frozen_string_literal: true

# Shared fixtures for issue #722 — CMS labor-related shares for OPPS/ASC wage
# adjustment. Tests create rows directly; the builder loads db/data/cms_labor_shares.csv.
module CmsLaborShareHelpers
  OPPS_LABOR_SHARE = BigDecimal("0.6000")
  ASC_LABOR_SHARE = BigDecimal("0.5000")

  def seed_opps_labor_share(calendar_year:, labor_share: OPPS_LABOR_SHARE, source: "synthetic test fixture")
    Corvid::CmsLaborShare.find_or_create_by!(
      payment_system: "opps",
      calendar_year: calendar_year
    ) do |row|
      row.labor_share = labor_share
      row.source = source
      row.release_label = "test_opps_cy#{calendar_year}"
    end
  end

  def seed_asc_labor_share(calendar_year:, labor_share: ASC_LABOR_SHARE, source: "synthetic test fixture")
    Corvid::CmsLaborShare.find_or_create_by!(
      payment_system: "asc",
      calendar_year: calendar_year
    ) do |row|
      row.labor_share = labor_share
      row.source = source
      row.release_label = "test_asc_cy#{calendar_year}"
    end
  end

  # ADR 0004: exact BigDecimal, rounded to cents at the end.
  def opps_labor_adjusted_rate(weight:, conversion_factor:, wage_index:, labor_share: OPPS_LABOR_SHARE)
    w = BigDecimal(weight.to_s)
    cf = BigDecimal(conversion_factor.to_s)
    wi = BigDecimal(wage_index.to_s)
    ls = BigDecimal(labor_share.to_s)
    (w * cf * (ls * wi + (1 - ls))).round(2)
  end

  def asc_labor_adjusted_rate(weight:, conversion_factor:, wage_index:, labor_share: ASC_LABOR_SHARE)
    w = BigDecimal(weight.to_s)
    cf = BigDecimal(conversion_factor.to_s)
    wi = BigDecimal(wage_index.to_s)
    ls = BigDecimal(labor_share.to_s)
    (w * cf * (ls * wi + (1 - ls))).round(2)
  end
end
