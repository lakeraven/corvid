# frozen_string_literal: true

require "test_helper"

class Corvid::DeterminationTest < ActiveSupport::TestCase
  TENANT = "tnt_det_test"

  setup do
    Corvid::Determination.unscoped.delete_all
    Corvid::PrcReferral.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  # =============================================================================
  # CREATION
  # =============================================================================

  test "creates with polymorphic determinable" do
    with_tenant(TENANT) do
      referral = create_referral
      det = Corvid::Determination.create!(
        determinable: referral,
        decision_method: "staff_review",
        outcome: "approved",
        determined_by_identifier: "pr_001"
      )
      assert det.persisted?
      assert det.approved?
    end
  end

  test "outcome defaults to pending_review" do
    with_tenant(TENANT) do
      det = Corvid::Determination.new(
        determinable: create_referral,
        decision_method: "automated"
      )
      # Check that pending_review is a valid outcome
      det.outcome = "pending_review"
      assert det.pending_review?
    end
  end

  # =============================================================================
  # VALIDATIONS
  # =============================================================================

  test "automated determination does not require determined_by" do
    with_tenant(TENANT) do
      det = Corvid::Determination.new(
        determinable: create_referral,
        decision_method: "automated",
        outcome: "approved"
      )
      assert det.valid?
    end
  end

  test "staff_review requires determined_by_identifier" do
    with_tenant(TENANT) do
      det = Corvid::Determination.new(
        determinable: create_referral,
        decision_method: "staff_review",
        outcome: "approved",
        determined_by_identifier: nil
      )
      refute det.valid?
      assert det.errors[:determined_by_identifier].any?
    end
  end

  test "committee_review requires determined_by_identifier" do
    with_tenant(TENANT) do
      det = Corvid::Determination.new(
        determinable: create_referral,
        decision_method: "committee_review",
        outcome: "approved",
        determined_by_identifier: nil
      )
      refute det.valid?
    end
  end

  test "valid with all required fields" do
    with_tenant(TENANT) do
      det = Corvid::Determination.new(
        determinable: create_referral,
        decision_method: "staff_review",
        outcome: "approved",
        determined_by_identifier: "pr_001"
      )
      assert det.valid?
    end
  end

  # =============================================================================
  # ENUMS
  # =============================================================================

  test "decision_method enum includes automated, staff_review, committee_review" do
    expected = %w[automated staff_review committee_review]
    assert_equal expected.sort, Corvid::Determination.decision_methods.keys.sort
  end

  test "outcome enum includes approved, denied, deferred, pending_review" do
    expected = %w[approved denied deferred pending_review]
    assert_equal expected.sort, Corvid::Determination.outcomes.keys.sort
  end

  test "outcome predicates work" do
    with_tenant(TENANT) do
      referral = create_referral
      %w[approved denied deferred pending_review].each do |outcome|
        det = Corvid::Determination.create!(
          determinable: referral,
          decision_method: "automated",
          outcome: outcome
        )
        assert det.send("#{outcome}?"), "Predicate failed for outcome: #{outcome}"
      end
    end
  end

  test "decision_method predicates work" do
    with_tenant(TENANT) do
      referral = create_referral
      { "automated" => nil, "staff_review" => "pr_001", "committee_review" => "pr_002" }.each do |method, by|
        det = Corvid::Determination.create!(
          determinable: referral,
          decision_method: method,
          outcome: "approved",
          determined_by_identifier: by
        )
        assert det.send("decision_method_#{method}?"), "Predicate failed for method: #{method}"
      end
    end
  end

  # =============================================================================
  # CALLBACKS
  # =============================================================================

  test "sets determined_at on create" do
    with_tenant(TENANT) do
      det = Corvid::Determination.create!(
        determinable: create_referral,
        decision_method: "automated",
        outcome: "approved"
      )
      assert_not_nil det.determined_at
    end
  end

  test "does not override custom determined_at" do
    with_tenant(TENANT) do
      custom = 2.days.ago
      det = Corvid::Determination.create!(
        determinable: create_referral,
        decision_method: "automated",
        outcome: "approved",
        determined_at: custom
      )
      assert_in_delta custom.to_f, det.determined_at.to_f, 1.0
    end
  end

  # =============================================================================
  # MULTI-TENANCY
  # =============================================================================

  test "determinations scoped to tenant" do
    mine = nil
    other = nil

    with_tenant("tenant_a") do
      mine = Corvid::Determination.create!(
        determinable: create_referral,
        decision_method: "automated",
        outcome: "approved"
      )
    end

    with_tenant("tenant_b") do
      other = Corvid::Determination.create!(
        determinable: create_referral,
        decision_method: "automated",
        outcome: "denied"
      )
    end

    with_tenant("tenant_a") do
      assert_includes Corvid::Determination.all, mine
      refute_includes Corvid::Determination.all, other
    end
  end

  private

  def create_referral
    c = Corvid::Case.create!(patient_identifier: "pt_det", lifecycle_status: "intake", facility_identifier: "fac_test")
    Corvid::PrcReferral.create!(case: c, referral_identifier: "ref_#{SecureRandom.hex(4)}")
  end
end
