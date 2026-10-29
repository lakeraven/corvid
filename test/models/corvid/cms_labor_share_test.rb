# frozen_string_literal: true

require "test_helper"

module Corvid
  class CmsLaborShareTest < ActiveSupport::TestCase
    include CmsLaborShareHelpers

    def valid_opps_attrs
      {
        payment_system: "opps",
        calendar_year: 2026,
        labor_share: BigDecimal("0.6000"),
        source: "CMS OPPS Final Rule CY2026 Table 1B (synthetic citation for tests)"
      }
    end

    test "valid opps row persists" do
      row = CmsLaborShare.create!(valid_opps_attrs)
      assert_equal "opps", row.payment_system
      assert_equal 2026, row.calendar_year
      assert_equal BigDecimal("0.6000"), row.labor_share
    end

    test "payment_system must be opps or asc" do
      row = CmsLaborShare.new(valid_opps_attrs.merge(payment_system: "ipps"))
      refute row.valid?
      assert_includes row.errors[:payment_system], "is not included in the list"

      assert_db_rejects(
        CmsLaborShare.create!(valid_opps_attrs),
        payment_system: "pfs"
      )
    end

    test "labor_share must be strictly between 0 and 1" do
      row = CmsLaborShare.new(valid_opps_attrs.merge(labor_share: BigDecimal("1.0000")))
      refute row.valid?

      row.labor_share = BigDecimal("0")
      refute row.valid?

      assert_db_rejects(
        CmsLaborShare.create!(valid_opps_attrs),
        labor_share: BigDecimal("1.0000")
      )
      assert_db_rejects(
        CmsLaborShare.create!(valid_opps_attrs.merge(calendar_year: 2025)),
        labor_share: BigDecimal("0")
      )
    end

    test "source is required" do
      row = CmsLaborShare.new(valid_opps_attrs.merge(source: nil))
      refute row.valid?
      assert_includes row.errors[:source], "can't be blank"
    end

    test "unique on payment_system and calendar_year" do
      CmsLaborShare.create!(valid_opps_attrs)
      dup = CmsLaborShare.new(valid_opps_attrs.merge(labor_share: BigDecimal("0.5000")))
      refute dup.valid?
      assert dup.errors[:calendar_year].any? | dup.errors[:payment_system].any?
    end

    test "second create! for the same payment_system and calendar_year raises" do
      CmsLaborShare.create!(valid_opps_attrs)
      assert_raises(ActiveRecord::RecordInvalid) do
        CmsLaborShare.create!(valid_opps_attrs)
      end
    end

    test "shipped CMS labor share CSV loads and every row cites a source" do
      path = Corvid::Engine.root.join("db/data/cms_labor_shares.csv")
      assert path.exist?, "builder must ship cited labor share data at #{path}"

      CmsLaborShare.unscoped.delete_all
      count = CmsLaborShareLoader.load!(path: path)
      assert count.positive?, "loader must insert at least one labor share row"

      CmsLaborShare.find_each do |row|
        assert row.source.present?,
               "labor share row #{row.payment_system} CY#{row.calendar_year} must cite source"
      end
    end

    private

    def assert_db_rejects(record, attrs)
      error = assert_raises(ActiveRecord::StatementInvalid) do
        record.class.transaction(requires_new: true) do
          record.update_columns(attrs)
        end
      end
      message = error.cause&.message || error.message
      assert(
        message.match?(/check constraint|violates/i),
        "expected CHECK violation, got: #{message}"
      )
    end
  end
end
