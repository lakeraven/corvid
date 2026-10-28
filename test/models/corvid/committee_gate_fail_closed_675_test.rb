# frozen_string_literal: true

require "test_helper"

# Issue #675 / PR #693: committee gates fail closed on invalid cost and priority
# inputs (ADR 0004). These tests pin behaviour the panel reproduced as fail-open.
module Corvid
  class CommitteeGateFailClosed675Test < ActiveSupport::TestCase
    TENANT = "tnt_test"
    FACILITY = "fac_g675"
    PATIENT = "TEST,PATIENT G675"

    setup do
      Corvid.adapter.reset! if Corvid.adapter.respond_to?(:reset!)
    end

    # -- P1: invalid local committee costs ------------------------------------

    {
      BigDecimal("NaN") => "BigDecimal NaN",
      Float::NAN => "Float NAN",
      Float::INFINITY => "Float INFINITY",
      -Float::INFINITY => "Float negative infinity"
    }.each do |cost, label|
      test "local estimated_cost #{label} requires committee with CommitteeReview parity" do
        with_tenant(TENANT) do
          referral = referral_with_local_committee_cost(cost, medical_priority: 2)
          assert_committee_required_parity(referral)
        end
      end
    end

    {
      -75_000 => "negative Integer",
      BigDecimal("-1") => "negative BigDecimal",
      -5_000.0 => "negative Float",
      Money.from_amount(-100, "USD") => "negative Money USD"
    }.each do |cost, label|
      test "local estimated_cost #{label} requires committee with CommitteeReview parity" do
        with_tenant(TENANT) do
          referral = build_referral(estimated_cost: cost, medical_priority: 2)
          assert_committee_required_parity(referral)
        end
      end
    end

    {
      Money.from_amount(49_000, "EUR") => "EUR 49,000",
      Money.from_amount(40_000, "KWD") => "KWD 40,000"
    }.each do |cost, label|
      test "local estimated_cost #{label} requires committee with CommitteeReview parity" do
        with_tenant(TENANT) do
          referral = build_referral(estimated_cost: cost, medical_priority: 2)
          assert_committee_required_parity(referral)
        end
      end
    end

    # -- P1: invalid EHR committee costs --------------------------------------

    {
      BigDecimal("NaN") => "BigDecimal NaN",
      Float::NAN => "Float NAN",
      Float::INFINITY => "Float INFINITY",
      -75_000 => "negative integer",
      Money.from_amount(40_000, "KWD") => "KWD 40,000",
      Money.from_amount(49_000, "EUR") => "EUR 49,000"
    }.each do |ehr_cost, label|
      test "EHR estimated_cost #{label} requires committee with CommitteeReview parity" do
        with_tenant(TENANT) do
          referral = referral_with_ehr(
            local_cost: nil,
            ehr_cost: ehr_cost,
            local_priority: 2,
            ehr_priority: 2,
            referral_suffix: SecureRandom.hex(3)
          )
          referral.reload

          assert_committee_required_parity(referral)
        end
      end
    end

    # -- P3: priority outside 1..4 is unknown ---------------------------------

    {
      0 => "Integer 0",
      -1 => "Integer -1",
      5 => "Integer 5"
    }.each do |priority, label|
      test "local medical_priority #{label} requires committee with parity" do
        with_tenant(TENANT) do
          referral = build_referral(estimated_cost: 100, medical_priority: priority)
          assert_committee_required_parity(referral)
        end
      end
    end

    {
      "0" => "string 0",
      "5" => "string 5"
    }.each do |priority, label|
      test "local medical_priority #{label} requires committee with parity" do
        with_tenant(TENANT) do
          referral = build_referral(estimated_cost: 100, medical_priority: priority)
          assert_committee_required_parity(referral)
        end
      end
    end

    {
      0 => "EHR Integer 0",
      5 => "EHR Integer 5",
      "0" => "EHR string 0",
      "5" => "EHR string 5"
    }.each do |ehr_priority, label|
      test "#{label} requires committee with parity" do
        with_tenant(TENANT) do
          referral = referral_with_ehr(
            local_cost: 100,
            ehr_cost: 100,
            local_priority: nil,
            ehr_priority: ehr_priority,
            referral_suffix: SecureRandom.hex(3)
          )
          referral.reload

          assert_committee_required_parity(referral)
        end
      end
    end

    test "local medical_priority 1 and 2 alone do not require committee at low cost" do
      with_tenant(TENANT) do
        [ 1, 2 ].each do |priority|
          referral = build_referral(estimated_cost: 100, medical_priority: priority)
          assert_committee_not_required_parity(referral)
        end
      end
    end

    test "local medical_priority 3 and 4 require committee at low cost" do
      with_tenant(TENANT) do
        [ 3, 4 ].each do |priority|
          referral = build_referral(estimated_cost: 100, medical_priority: priority)
          assert_committee_required_parity(referral)
        end
      end
    end

    # -- P4: EHR cost wins when both present; extra decimals unknown -----------

    test "EHR cost at threshold requires committee when local cost is below threshold" do
      with_tenant(TENANT) do
        referral = referral_with_ehr(
          local_cost: 5_000,
          ehr_cost: 60_000,
          local_priority: 2,
          ehr_priority: 2
        )
        referral.reload

        assert_committee_required_parity(referral)
      end
    end

    test "EHR cost below threshold does not require committee when local cost is at threshold" do
      with_tenant(TENANT) do
        referral = referral_with_ehr(
          local_cost: 60_000,
          ehr_cost: 5_000,
          local_priority: 2,
          ehr_priority: 2
        )
        referral.reload

        assert_committee_not_required_parity(referral)
      end
    end

    test "EHR cost string with more than two decimal places requires committee with parity" do
      with_tenant(TENANT) do
        referral = referral_with_ehr(
          local_cost: nil,
          ehr_cost: "49999.999",
          local_priority: 2,
          ehr_priority: 2
        )
        referral.reload

        assert_committee_required_parity(referral)
      end
    end

    private

    def assert_committee_required_parity(referral)
      assert referral.requires_committee?, "PrcReferral must require committee"
      assert CommitteeReview.requires_committee_review?(referral),
        "CommitteeReview.requires_committee_review? must match PrcReferral"
      assert_equal referral.requires_committee?, CommitteeReview.requires_committee_review?(referral)
    end

    def assert_committee_not_required_parity(referral)
      refute referral.requires_committee?, "PrcReferral must not require committee"
      refute CommitteeReview.requires_committee_review?(referral),
        "CommitteeReview.requires_committee_review? must match PrcReferral"
      assert_equal referral.requires_committee?, CommitteeReview.requires_committee_review?(referral)
    end

    def build_referral(estimated_cost:, medical_priority:)
      kase = Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
      PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_g675_#{SecureRandom.hex(4)}",
        facility_identifier: FACILITY,
        estimated_cost: estimated_cost,
        medical_priority: medical_priority,
        flagged_for_review: false
      )
    end

    # Money rejects non-finite amounts at assign time; the committee gate must
    # still fail closed when such a value is present on the referral row.
    def referral_with_local_committee_cost(cost, medical_priority:)
      referral = build_referral(estimated_cost: nil, medical_priority: medical_priority)
      referral.define_singleton_method(:estimated_cost) { cost }
      referral
    end

    def referral_with_ehr(local_cost:, ehr_cost:, local_priority:, ehr_priority:, referral_suffix: nil)
      referral = build_referral(estimated_cost: local_cost, medical_priority: local_priority)

      Corvid.adapter.add_referral(
        referral.referral_identifier,
        patient_identifier: PATIENT,
        status: "pending",
        estimated_cost: ehr_cost,
        medical_priority_level: ehr_priority,
        emergent: false,
        urgent: false,
        chs_approval_status: "P",
        service_requested: "TEST"
      )
      referral
    end
  end
end
