# frozen_string_literal: true

require "test_helper"

class Corvid::ZipCbsaCrosswalkTest < ActiveSupport::TestCase
  teardown do
    next unless Corvid.const_defined?(:ZipCbsaCrosswalk, false)

    Corvid::ZipCbsaCrosswalk.unscoped.delete_all
  rescue ActiveRecord::StatementInvalid
    nil
  end

  test "valid urban row requires fiscal_year, five-digit zip, and five-digit cbsa" do
    row = Corvid::ZipCbsaCrosswalk.new(
      fiscal_year: 2026, zip: "88101", cbsa: "98765", release_label: "test"
    )
    assert row.valid?
  end

  test "valid rural row accepts a two-digit CMS rural state cbsa code" do
    row = Corvid::ZipCbsaCrosswalk.new(
      fiscal_year: 2026, zip: "88202", cbsa: "12", release_label: "test"
    )
    assert row.valid?
  end

  test "requires fiscal_year" do
    row = Corvid::ZipCbsaCrosswalk.new(zip: "88101", cbsa: "98765")
    refute row.valid?
    assert_includes row.errors[:fiscal_year], "can't be blank"
  end

  test "zip must be exactly five ASCII digits" do
    invalid = Corvid::ZipCbsaCrosswalk.new(fiscal_year: 2026, zip: "8810", cbsa: "98765")
    refute invalid.valid?
    assert invalid.errors[:zip].any?

    letters = Corvid::ZipCbsaCrosswalk.new(fiscal_year: 2026, zip: "8810A", cbsa: "98765")
    refute letters.valid?
    assert letters.errors[:zip].any?
  end

  test "cbsa must be five urban digits or two rural digits" do
    three = Corvid::ZipCbsaCrosswalk.new(fiscal_year: 2026, zip: "88101", cbsa: "123")
    refute three.valid?
    assert three.errors[:cbsa].any?

    six = Corvid::ZipCbsaCrosswalk.new(fiscal_year: 2026, zip: "88101", cbsa: "123456")
    refute six.valid?
    assert six.errors[:cbsa].any?
  end

  test "unique index rejects duplicate fiscal_year and zip" do
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2026, zip: "88303", cbsa: "98765", release_label: "first"
    )
    duplicate = Corvid::ZipCbsaCrosswalk.new(
      fiscal_year: 2026, zip: "88303", cbsa: "11111", release_label: "second"
    )

    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end
end
