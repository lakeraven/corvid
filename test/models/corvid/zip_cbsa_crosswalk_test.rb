# frozen_string_literal: true

require "test_helper"

class Corvid::ZipCbsaCrosswalkTest < ActiveSupport::TestCase
  setup do
    cleanup_zip_cbsa_crosswalk_rows!
  end

  teardown do
    cleanup_zip_cbsa_crosswalk_rows!
  end

  def cleanup_zip_cbsa_crosswalk_rows!
    return unless Corvid.const_defined?(:ZipCbsaCrosswalk, false)

    Corvid::ZipCbsaCrosswalk.unscoped.delete_all
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

  test "fiscal_year must be between 2000 and 2100" do
    low = Corvid::ZipCbsaCrosswalk.new(fiscal_year: 1999, zip: "88101", cbsa: "98765")
    refute low.valid?
    assert low.errors[:fiscal_year].any?

    high = Corvid::ZipCbsaCrosswalk.new(fiscal_year: 2101, zip: "88101", cbsa: "98765")
    refute high.valid?
    assert high.errors[:fiscal_year].any?
  end

  test "database check constraint rejects a four-digit zip on raw insert" do
    now = Time.current
    assert_raises(ActiveRecord::StatementInvalid) do
      Corvid::ZipCbsaCrosswalk.transaction(requires_new: true) do
        Corvid::ZipCbsaCrosswalk.insert_all(
          [ { fiscal_year: 2026, zip: "8810", cbsa: "98765", release_label: "raw",
              created_at: now, updated_at: now } ]
        )
      end
    end
  end

  test "database check constraint rejects a three-digit cbsa on raw insert" do
    now = Time.current
    assert_raises(ActiveRecord::StatementInvalid) do
      Corvid::ZipCbsaCrosswalk.transaction(requires_new: true) do
        Corvid::ZipCbsaCrosswalk.insert_all(
          [ { fiscal_year: 2026, zip: "88101", cbsa: "123", release_label: "raw",
              created_at: now, updated_at: now } ]
        )
      end
    end
  end

  test "database check constraint rejects fiscal_year outside 2000..2100 on raw insert" do
    now = Time.current
    assert_raises(ActiveRecord::StatementInvalid) do
      Corvid::ZipCbsaCrosswalk.transaction(requires_new: true) do
        Corvid::ZipCbsaCrosswalk.insert_all(
          [ { fiscal_year: 1999, zip: "88101", cbsa: "98765", release_label: "raw",
              created_at: now, updated_at: now } ]
        )
      end
    end
  end

  test "zip with a leading zero is stored as five digits" do
    Corvid::ZipCbsaCrosswalk.create!(
      fiscal_year: 2026, zip: "01234", cbsa: "98765", release_label: "test"
    )

    row = Corvid::ZipCbsaCrosswalk.find_by(fiscal_year: 2026, zip: "01234")
    assert_equal "01234", row.zip
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
