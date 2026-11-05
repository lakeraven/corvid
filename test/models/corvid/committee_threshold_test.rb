# frozen_string_literal: true

require "test_helper"

module Corvid
  class CommitteeThresholdTest < ActiveSupport::TestCase
    TENANT = "tnt_threshold"
    FACILITY = "fac_threshold"

    # -- Cost boundary tests --

    test "cost at threshold requires committee" do
      with_tenant(TENANT) { assert build_referral(estimated_cost: 50_000).requires_committee? }
    end

    test "cost below threshold does not require committee" do
      with_tenant(TENANT) { refute build_referral(estimated_cost: 49_999.99).requires_committee? }
    end

    test "cost above threshold requires committee" do
      with_tenant(TENANT) { assert build_referral(estimated_cost: 50_000.01).requires_committee? }
    end

    test "zero cost does not require committee" do
      with_tenant(TENANT) { refute build_referral(estimated_cost: 0).requires_committee? }
    end

    test "nil cost does not require committee" do
      with_tenant(TENANT) { refute build_referral(estimated_cost: nil).requires_committee? }
    end

    # -- Priority tests --

    test "priority 3 requires committee" do
      with_tenant(TENANT) { assert build_referral(estimated_cost: 100, medical_priority: 3).requires_committee? }
    end

    test "priority 2 does not require committee" do
      with_tenant(TENANT) { refute build_referral(estimated_cost: 100, medical_priority: 2).requires_committee? }
    end

    test "priority 4 requires committee" do
      with_tenant(TENANT) { assert build_referral(estimated_cost: 100, medical_priority: 4).requires_committee? }
    end

    test "nil priority requires committee review" do
      with_tenant(TENANT) { assert build_referral(estimated_cost: 100, medical_priority: nil).requires_committee? }
    end

    # -- Flag tests --

    test "flagged referral requires committee regardless of cost" do
      with_tenant(TENANT) { assert build_referral(estimated_cost: 100, flagged_for_review: true).requires_committee? }
    end

    test "unflagged low-cost referral does not require committee" do
      with_tenant(TENANT) { refute build_referral(estimated_cost: 100, flagged_for_review: false).requires_committee? }
    end

    # -- Parity with CommitteeReview class method --

    test "class method agrees with instance method at threshold" do
      with_tenant(TENANT) do
        r = build_referral(estimated_cost: 50_000)
        assert_equal r.requires_committee?, CommitteeReview.requires_committee_review?(r)
      end
    end

    test "class method agrees with instance method below threshold" do
      with_tenant(TENANT) do
        r = build_referral(estimated_cost: 49_999)
        assert_equal r.requires_committee?, CommitteeReview.requires_committee_review?(r)
      end
    end

    test "class method agrees for high priority" do
      with_tenant(TENANT) do
        r = build_referral(estimated_cost: 100, medical_priority: 3)
        assert_equal r.requires_committee?, CommitteeReview.requires_committee_review?(r)
      end
    end

    # Issue #675: local cost exactness (ADR 0004) and EHR fallback via shared gate.
    test "local BigDecimal cost at threshold requires committee" do
      with_tenant("tnt_test") do
        assert build_referral(estimated_cost: BigDecimal("50000"), medical_priority: 2).requires_committee?
      end
    end

    test "local Float cost at threshold requires committee via exact string form" do
      with_tenant("tnt_test") do
        assert build_referral(estimated_cost: 50_000.0, medical_priority: 2).requires_committee?
      end
    end

    test "EHR dollar string cost at threshold requires committee when local cost is nil" do
      with_tenant("tnt_test") do
        Corvid.adapter.reset! if Corvid.adapter.respond_to?(:reset!)
        r = build_referral(estimated_cost: nil, medical_priority: 2)
        Corvid.adapter.add_referral(
          r.referral_identifier,
          patient_identifier: "pt_thr",
          status: "pending",
          estimated_cost: "$60,000",
          medical_priority_level: 2,
          emergent: false,
          urgent: false,
          chs_approval_status: "P",
          service_requested: "TEST"
        )
        r.reload

        assert r.requires_committee?
        assert_equal r.requires_committee?, CommitteeReview.requires_committee_review?(r)
      end
    end

    private

    def build_referral(estimated_cost: nil, medical_priority: 1, flagged_for_review: false)
      kase = Case.create!(patient_identifier: "pt_thr", facility_identifier: FACILITY)
      PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_#{SecureRandom.hex(4)}",
        facility_identifier: FACILITY,
        estimated_cost: estimated_cost,
        medical_priority: medical_priority,
        flagged_for_review: flagged_for_review
      )
    end
  end
end
