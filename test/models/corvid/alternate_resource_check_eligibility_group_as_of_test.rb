# frozen_string_literal: true

require "test_helper"

# Issue #695: eligibility_group_as_of is set only with stated sources.
class Corvid::AlternateResourceCheckEligibilityGroupAsOfTest < ActiveSupport::TestCase
  TENANT = "tnt_test"
  ELIGIBILITY_GROUP_AS_OF_SOURCE_CHECK = "corvid_arc_eligibility_group_as_of_stated_source_check"

  test "database rejects eligibility_group_as_of with staff_entry source" do
    with_tenant(TENANT) do
      assert check_constraint_exists?(ELIGIBILITY_GROUP_AS_OF_SOURCE_CHECK)

      check = create_medicaid_check!
      assert_raises(ActiveRecord::CheckViolation) do
        Corvid::AlternateResourceCheck.transaction(requires_new: true) do
          update_eligibility_group_as_of_columns!(
            check,
            eligibility_group: "other",
            eligibility_group_source: "staff_entry",
            eligibility_group_as_of: Time.utc(2026, 10, 10, 12, 0, 0)
          )
        end
      end
    end
  end

  test "database rejects eligibility_group_as_of with inferred source" do
    with_tenant(TENANT) do
      assert check_constraint_exists?(ELIGIBILITY_GROUP_AS_OF_SOURCE_CHECK)

      check = create_medicaid_check!
      assert_raises(ActiveRecord::CheckViolation) do
        Corvid::AlternateResourceCheck.transaction(requires_new: true) do
          update_eligibility_group_as_of_columns!(
            check,
            eligibility_group: "expansion_adult",
            eligibility_group_source: "inferred",
            eligibility_group_as_of: Time.utc(2026, 10, 10, 12, 0, 0)
          )
        end
      end
    end
  end

  test "model rejects staff_entry with eligibility_group_as_of" do
    with_tenant(TENANT) do
      check = build_medicaid_check
      check.eligibility_group = "other"
      check.eligibility_group_source = "staff_entry"
      check.eligibility_group_set_at = Time.current
      check.eligibility_group_as_of = Time.utc(2026, 10, 10, 12, 0, 0)

      refute check.valid?
      assert check.errors[:eligibility_group_as_of].present? || check.errors[:base].present?
    end
  end

  private

  def create_case
    Corvid::Case.create!(
      patient_identifier: "pt_arc_asof_test",
      lifecycle_status: "intake",
      facility_identifier: "fac_test"
    )
  end

  def create_referral
    Corvid::PrcReferral.create!(case: create_case, referral_identifier: "ref_#{SecureRandom.hex(4)}")
  end

  def create_medicaid_check!
    Corvid::AlternateResourceCheck.create!(
      prc_referral: create_referral,
      resource_type: "medicaid",
      status: "checking"
    )
  end

  def build_medicaid_check
    Corvid::AlternateResourceCheck.new(
      prc_referral: create_referral,
      resource_type: "medicaid",
      status: "checking"
    )
  end

  def check_constraint_exists?(name)
    sql = <<~SQL.squish
      SELECT 1
      FROM pg_constraint c
      INNER JOIN pg_class t ON c.conrelid = t.oid
      WHERE t.relname = 'corvid_alternate_resource_checks'
        AND c.conname = #{ActiveRecord::Base.connection.quote(name)}
        AND c.contype = 'c'
      LIMIT 1
    SQL
    ActiveRecord::Base.connection.select_value(sql).present?
  end

  def update_eligibility_group_as_of_columns!(
    check,
    eligibility_group:,
    eligibility_group_source:,
    eligibility_group_as_of:
  )
    conn = ActiveRecord::Base.connection
    group_sql = eligibility_group.nil? ? "NULL" : conn.quote(eligibility_group)
    source_sql = eligibility_group_source.nil? ? "NULL" : conn.quote(eligibility_group_source)
    as_of_sql = eligibility_group_as_of.nil? ? "NULL" : conn.quote(eligibility_group_as_of)
    conn.execute(<<~SQL.squish)
      UPDATE corvid_alternate_resource_checks
      SET eligibility_group = #{group_sql},
          eligibility_group_source = #{source_sql},
          eligibility_group_set_at = NOW(),
          eligibility_group_as_of = #{as_of_sql}
      WHERE id = #{check.id}
    SQL
  end
end
