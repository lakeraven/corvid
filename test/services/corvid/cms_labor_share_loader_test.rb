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

    test "load! refuses CSV with no data rows and leaves the table unchanged" do
      Dir.mktmpdir do |dir|
        valid_path = File.join(dir, "valid.csv")
        File.write(
          valid_path,
          <<~CSV
            payment_system,calendar_year,labor_share,source,release_label
            opps,2024,0.6000,synthetic valid row,
            asc,2025,0.5000,synthetic valid row,
          CSV
        )
        CmsLaborShareLoader.load!(path: valid_path)
        snapshot = labor_share_table_snapshot

        header_only_path = File.join(dir, "header_only.csv")
        File.write(
          header_only_path,
          <<~CSV
            # CMS labor shares
            payment_system,calendar_year,labor_share,source,release_label
          CSV
        )

        error = assert_raises(CmsLaborShareLoader::MalformedFileError) do
          CmsLaborShareLoader.load!(path: header_only_path)
        end
        assert_match(/no labor share data rows/, error.message)
        assert_equal snapshot, labor_share_table_snapshot,
                     "header-only CSV must not replace loaded labor shares"
      end
    end

    test "load! refuses an empty labor share CSV and leaves the table unchanged" do
      Dir.mktmpdir do |dir|
        valid_path = File.join(dir, "valid.csv")
        File.write(
          valid_path,
          <<~CSV
            payment_system,calendar_year,labor_share,source,release_label
            opps,2024,0.6000,synthetic valid row,
          CSV
        )
        CmsLaborShareLoader.load!(path: valid_path)
        snapshot = labor_share_table_snapshot

        empty_path = File.join(dir, "empty.csv")
        File.write(empty_path, "")

        error = assert_raises(CmsLaborShareLoader::MalformedFileError) do
          CmsLaborShareLoader.load!(path: empty_path)
        end
        assert_match(/missing columns/, error.message)
        assert_equal snapshot, labor_share_table_snapshot,
                     "empty CSV must not replace loaded labor shares"
      end
    end

    private

    def labor_share_table_snapshot
      CmsLaborShare.order(:payment_system, :calendar_year).map do |row|
        [
          row.payment_system,
          row.calendar_year,
          row.labor_share,
          row.source,
          row.release_label
        ]
      end
    end
  end
end
