# frozen_string_literal: true

require "test_helper"

class Corvid::DeterminationTest < ActiveSupport::TestCase
  TENANT = "tnt_det_test"

  setup do
    Corvid::Determination.unscoped.delete_all
    Corvid::PrcReferral.unscoped.delete_all
    Corvid::Case.unscoped.delete_all
  end

  test "creates with polymorphic determinable" do
    with_tenant(TENANT) do
      referral = create_referral
      det = Corvid::Determination.create!(
        determinable: referral,
        decision_method: "staff_review",
        outcome: "approved",
        determined_by_identifier: "pr_001",
        reasons_token: "tok_test"
      )
      assert det.persisted?
      assert det.approved?
    end
  end

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

  test "manual determination requires determined_by" do
    with_tenant(TENANT) do
      det = Corvid::Determination.new(
        determinable: create_referral,
        decision_method: "staff_review",
        outcome: "approved",
        determined_by_identifier: nil
      )
      refute det.valid?
    end
  end

  test "outcome enum values" do
    with_tenant(TENANT) do
      referral = create_referral
      %w[approved denied deferred].each do |outcome|
        attrs = { determinable: referral, decision_method: "automated", outcome: outcome }
        attrs[:reasons_token] = "tok_test" if outcome == "denied"
        det = Corvid::Determination.create!(**attrs)
        assert det.send("#{outcome}?")
      end
    end
  end

  # -- Defaults ---------------------------------------------------------------

  test "outcome can be set to pending_review" do
    with_tenant(TENANT) do
      det = Corvid::Determination.new(
        determinable: create_referral,
        decision_method: :automated,
        outcome: :pending_review
      )
      assert det.pending_review?
    end
  end

  # -- Validations: reasons ---------------------------------------------------

  test "requires reasons_token when denied" do
    with_tenant(TENANT) do
      det = Corvid::Determination.new(
        determinable: create_referral,
        decision_method: "automated",
        outcome: :denied,
        reasons_token: nil
      )
      refute det.valid?
      assert det.errors[:reasons_token].any?
    end
  end

  # -- Timestamps -------------------------------------------------------------

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

  test "can override determined_at" do
    with_tenant(TENANT) do
      custom_time = 1.day.ago
      det = Corvid::Determination.create!(
        determinable: create_referral,
        decision_method: "automated",
        outcome: "approved",
        determined_at: custom_time
      )
      assert_in_delta custom_time.to_i, det.determined_at.to_i, 1
    end
  end

  # -- Scopes -----------------------------------------------------------------

  test "chronological scope orders by created_at asc" do
    with_tenant(TENANT) do
      referral = create_referral
      d1 = Corvid::Determination.create!(determinable: referral, decision_method: "automated", outcome: "pending_review", created_at: 2.days.ago)
      d2 = Corvid::Determination.create!(determinable: referral, decision_method: "automated", outcome: "approved", created_at: 1.day.ago)
      d3 = Corvid::Determination.create!(determinable: referral, decision_method: "automated", outcome: "approved", created_at: Time.current)

      ordered = Corvid::Determination.chronological
      assert_equal [d1, d2, d3], ordered.to_a
    end
  end

  test "reverse_chronological scope orders by created_at desc" do
    with_tenant(TENANT) do
      referral = create_referral
      d1 = Corvid::Determination.create!(determinable: referral, decision_method: "automated", outcome: "pending_review", created_at: 2.days.ago)
      d2 = Corvid::Determination.create!(determinable: referral, decision_method: "automated", outcome: "approved", created_at: Time.current)

      ordered = Corvid::Determination.reverse_chronological
      assert_equal d2, ordered.first
    end
  end

  # -- Summary ----------------------------------------------------------------

  test "summary includes decision method and outcome" do
    with_tenant(TENANT) do
      det = Corvid::Determination.new(
        determinable: create_referral,
        decision_method: :automated,
        outcome: :approved,
        reasons_token: "tok_elig"
      )
      summary = det.summary
      assert_includes summary, "Automated"
      assert_includes summary, "Approved"
    end
  end

  # -- decision_method enum ---------------------------------------------------

  test "decision_method enum includes expected values" do
    expected_keys = %w[automated staff_review committee_review]
    assert_equal expected_keys.sort, Corvid::Determination.decision_methods.keys.sort
  end

  test "outcome enum includes expected values" do
    expected_keys = %w[approved denied deferred pending_review]
    assert_equal expected_keys.sort, Corvid::Determination.outcomes.keys.sort
  end

  # -- valid with all fields --------------------------------------------------

  test "valid with all required fields" do
    with_tenant(TENANT) do
      det = Corvid::Determination.new(
        determinable: create_referral,
        decision_method: :automated,
        outcome: :approved,
        reasons_token: "tok_reason"
      )
      assert det.valid?
    end
  end

  private

  def create_referral
    c = Corvid::Case.create!(patient_identifier: "pt_det", lifecycle_status: "intake", facility_identifier: "fac_test")
    Corvid::PrcReferral.create!(case: c, referral_identifier: "ref_#{SecureRandom.hex(4)}")
  end
end
