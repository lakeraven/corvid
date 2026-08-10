# frozen_string_literal: true

require "test_helper"

class Corvid::MedicaidExemptionTest < ActiveSupport::TestCase
  TENANT = "tnt_exempt_test"

  # -- Creation / validations ------------------------------------------------

  test "creates a valid asserted exemption" do
    with_tenant(TENANT) do
      exemption = build_exemption
      assert exemption.valid?, exemption.errors.full_messages.inspect
      assert exemption.save
      assert exemption.status_asserted?
    end
  end

  test "requires person_identifier" do
    with_tenant(TENANT) do
      exemption = build_exemption(person_identifier: nil)
      refute exemption.valid?
      assert exemption.errors[:person_identifier].any?
    end
  end

  test "requires verified_at and verification_source (verified-assertion provenance)" do
    with_tenant(TENANT) do
      exemption = build_exemption(verified_at: nil, verification_source: nil)
      refute exemption.valid?
      assert exemption.errors[:verified_at].any?
      assert exemption.errors[:verification_source].any?
    end
  end

  test "exemption_type must be a valid enum value" do
    with_tenant(TENANT) do
      assert_raises(ArgumentError) { build_exemption(exemption_type: "bogus") }
    end
  end

  test "exemption_type enum includes both HR-1 categories" do
    assert_equal %w[six_month_redetermination work_requirement],
                 Corvid::MedicaidExemption.exemption_types.keys.sort
  end

  # -- Uniqueness of asserted exemptions -------------------------------------

  test "only one asserted exemption of a type per person" do
    with_tenant(TENANT) do
      build_exemption.save!
      dup = build_exemption
      refute dup.valid?
      assert dup.errors[:exemption_type].any?
    end
  end

  test "same type may exist for different people" do
    with_tenant(TENANT) do
      build_exemption(person_identifier: "pt_a").save!
      other = build_exemption(person_identifier: "pt_b")
      assert other.valid?
    end
  end

  test "a revoked exemption does not block a new asserted one" do
    with_tenant(TENANT) do
      build_exemption(status: "revoked").save!
      fresh = build_exemption(status: "asserted")
      assert fresh.valid?, fresh.errors.full_messages.inspect
    end
  end

  # -- Scopes / predicates ---------------------------------------------------

  test "active scope returns only asserted" do
    with_tenant(TENANT) do
      asserted = build_exemption.tap(&:save!)
      build_exemption(person_identifier: "pt_rev", status: "revoked").save!

      results = Corvid::MedicaidExemption.active
      assert_includes results, asserted
      assert(results.all?(&:status_asserted?))
    end
  end

  test "in_effect? is false past expiry" do
    with_tenant(TENANT) do
      exemption = build_exemption(expires_at: 1.day.ago)
      refute exemption.in_effect?
    end
  end

  test "in_effect? is true when asserted with no expiry" do
    with_tenant(TENANT) do
      assert build_exemption(expires_at: nil).in_effect?
    end
  end

  # -- Tenant isolation ------------------------------------------------------

  test "exemptions are scoped to current tenant" do
    inside = nil
    with_tenant(TENANT) { inside = build_exemption.tap(&:save!) }
    with_tenant("tnt_other") { build_exemption.save! }

    with_tenant(TENANT) do
      assert_includes Corvid::MedicaidExemption.all, inside
      assert_equal 1, Corvid::MedicaidExemption.count
    end
  end

  private

  def build_exemption(**attrs)
    Corvid::MedicaidExemption.new(
      {
        person_identifier: "pt_exempt",
        exemption_type: "work_requirement",
        status: "asserted",
        basis: "ai_an_ihs_beneficiary",
        as_of_date: Date.current,
        effective_date: Date.current,
        verified_at: Time.current,
        verification_source: "Corvid::Adapters::MockAdapter",
        verification_confidence: "verified"
      }.merge(attrs)
    )
  end
end
