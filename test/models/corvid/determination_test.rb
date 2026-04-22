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
        det = Corvid::Determination.create!(
          determinable: referral,
          decision_method: "automated",
          outcome: outcome,
          
        )
        assert det.send("#{outcome}?")
      end
    end
  end

  private

  def create_referral
    c = Corvid::Case.create!(patient_identifier: "pt_det", lifecycle_status: "intake", facility_identifier: "fac_test")
    Corvid::PrcReferral.create!(case: c, referral_identifier: "ref_#{SecureRandom.hex(4)}")
  end
end
