# frozen_string_literal: true

require "test_helper"

module Corvid
  class CmsLaborShareLoaderTest < ActiveSupport::TestCase
    include CmsLaborShareHelpers

    test "load! refuses CSV labor_share values with more than four decimal places" do
      CmsLaborShare.create!(payment_system: "opps", calendar_year: 2020,
                            labor_share: BigDecimal("0.6000"), source: "existing row")
      csv = <<~CSV
        payment_system,calendar_year,labor_share,source,release_label
        opps,2026,0.60005,synthetic over-precision test,
      CSV
      path = Rails.root.join("tmp/test_cms_labor_share_over_precision.csv")
      path.dirname.mkpath
      path.write(csv)

      assert_raises(CmsLaborShareLoader::MalformedFileError) do
        CmsLaborShareLoader.load!(path: path)
      end
      row = CmsLaborShare.find_by(payment_system: "opps", calendar_year: 2020)
      assert_equal BigDecimal("0.6000"), row.labor_share,
                   "failed load must leave the table unchanged"
      refute CmsLaborShare.exists?(payment_system: "opps", calendar_year: 2026)
    ensure
      path&.delete
    end
  end
end
