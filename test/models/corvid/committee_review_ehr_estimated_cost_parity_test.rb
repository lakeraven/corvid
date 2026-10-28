# frozen_string_literal: true

require "test_helper"

# Issue #675 / PR #693 (ADR 0004): EHR estimated_cost and medical_priority_level
# must parse exactly for committee gates; CommitteeReview delegates to PrcReferral.
module Corvid
  class CommitteeReviewEhrEstimatedCostParityTest < ActiveSupport::TestCase
    TENANT = "tnt_test"
    FACILITY = "fac_g693"
    PATIENT = "TEST,PATIENT G693"
    THRESHOLD = 50_000

    setup do
      Corvid.adapter.reset! if Corvid.adapter.respond_to?(:reset!)
    end

    test "requires_committee_review? agrees with PrcReferral when cost is only on the EHR" do
      with_tenant(TENANT) do
        referral = referral_with_ehr(
          local_cost: nil,
          ehr_cost: 60_000,
          local_priority: 2,
          ehr_priority: 2
        )
        referral.reload

        assert referral.requires_committee?, "PrcReferral must see EHR estimated_cost"
        assert CommitteeReview.requires_committee_review?(referral),
          "CommitteeReview must match PrcReferral when EHR cost is at or above threshold"
        assert_equal referral.requires_committee?, CommitteeReview.requires_committee_review?(referral)
      end
    end

    test "EHR estimated_cost $60,000 requires committee (reproduction)" do
      with_tenant(TENANT) do
        referral = referral_with_ehr(local_cost: nil, ehr_cost: "$60,000", local_priority: 2, ehr_priority: 2)
        referral.reload

        assert_committee_required_parity(referral)
      end
    end

    {
      "60000" => "plain digits",
      "60,000" => "grouped commas",
      "1,234,567" => "million grouped",
      "60000.50" => "two decimal places",
      " $60,000 " => "surrounding whitespace",
      60_000 => "integer",
      BigDecimal("60000") => "big decimal",
      60_000.0 => "float via string form"
    }.each do |ehr_cost, label|
      test "accepted EHR cost #{label} at threshold requires committee with parity" do
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

    {
      "49,999" => "below threshold grouped",
      "100" => "small plain amount",
      "49999.99" => "two decimal places below threshold"
    }.each do |ehr_cost, label|
      test "accepted EHR cost #{label} below threshold does not require committee" do
        with_tenant(TENANT) do
          referral = referral_with_ehr(
            local_cost: nil,
            ehr_cost: ehr_cost,
            local_priority: 2,
            ehr_priority: 2,
            referral_suffix: SecureRandom.hex(3)
          )
          referral.reload

          assert_committee_not_required_parity(referral)
        end
      end
    end

    {
      "60k" => "suffix shorthand",
      "about 60000" => "prose",
      "$60,00" => "bad grouping",
      "-5" => "negative",
      "" => "empty string",
      { dollars: 60_000 } => "hash",
      true => "boolean"
    }.each do |ehr_cost, label|
      test "unknown EHR cost #{label} requires committee with parity" do
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

    test "nil EHR and nil local cost does not require committee when priority is known low" do
      with_tenant(TENANT) do
        referral = referral_with_ehr(local_cost: nil, ehr_cost: nil, local_priority: 2, ehr_priority: 2)
        referral.reload

        assert_committee_not_required_parity(referral)
      end
    end

    test "absent EHR cost falls back to local estimated_cost for committee" do
      with_tenant(TENANT) do
        referral = referral_with_ehr(
          local_cost: THRESHOLD,
          ehr_cost: :omit,
          local_priority: 2,
          ehr_priority: :omit
        )
        referral.reload

        assert_committee_required_parity(referral)
      end
    end

    test "EHR medical_priority_level string 2 does not raise and does not require committee with low cost" do
      with_tenant(TENANT) do
        referral = referral_with_ehr(
          local_cost: 5_000,
          ehr_cost: 5_000,
          local_priority: nil,
          ehr_priority: "2"
        )
        referral.reload

        assert_nothing_raised { assert_committee_not_required_parity(referral) }
      end
    end

    test "EHR medical_priority_level string 2 reproduction does not raise" do
      with_tenant(TENANT) do
        referral = referral_with_ehr(
          local_cost: 5_000,
          ehr_cost: 5_000,
          local_priority: 2,
          ehr_priority: "2"
        )
        referral.reload

        assert_nothing_raised { referral.requires_committee? }
        assert_nothing_raised { CommitteeReview.requires_committee_review?(referral) }
      end
    end

    {
      "2" => "ascii digits",
      " 3 " => "stripped digits at committee boundary"
    }.each do |ehr_priority, label|
      test "accepted EHR priority #{label} parses for committee gate" do
        with_tenant(TENANT) do
          referral = referral_with_ehr(
            local_cost: 100,
            ehr_cost: 100,
            local_priority: nil,
            ehr_priority: ehr_priority,
            referral_suffix: SecureRandom.hex(3)
          )
          referral.reload

          assert_nothing_raised do
            if ehr_priority.to_s.strip.to_i >= 3
              assert_committee_required_parity(referral)
            else
              assert_committee_not_required_parity(referral)
            end
          end
        end
      end
    end

    {
      "high" => "word",
      "2.5" => "decimal string",
      "" => "empty",
      2.0 => "float"
    }.each do |ehr_priority, label|
      test "unknown EHR priority #{label} requires committee without raising" do
        with_tenant(TENANT) do
          referral = referral_with_ehr(
            local_cost: 100,
            ehr_cost: 100,
            local_priority: nil,
            ehr_priority: ehr_priority,
            referral_suffix: SecureRandom.hex(3)
          )
          referral.reload

          assert_nothing_raised { assert_committee_required_parity(referral) }
        end
      end
    end

    test "absent EHR priority falls back to local medical_priority" do
      with_tenant(TENANT) do
        referral = referral_with_ehr(
          local_cost: 100,
          ehr_cost: 100,
          local_priority: 2,
          ehr_priority: :omit
        )
        referral.reload

        assert_committee_not_required_parity(referral)
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

    def referral_with_ehr(local_cost:, ehr_cost:, local_priority:, ehr_priority:, referral_suffix: nil)
      kase = Case.create!(patient_identifier: PATIENT, facility_identifier: FACILITY)
      referral = PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_g693_#{referral_suffix || SecureRandom.hex(4)}",
        facility_identifier: FACILITY,
        estimated_cost: local_cost,
        medical_priority: local_priority,
        flagged_for_review: false
      )

      adapter_attrs = {
        patient_identifier: PATIENT,
        status: "pending",
        emergent: false,
        urgent: false,
        chs_approval_status: "P",
        service_requested: "TEST"
      }
      adapter_attrs[:estimated_cost] = ehr_cost unless ehr_cost == :omit
      adapter_attrs[:medical_priority_level] = ehr_priority unless ehr_priority == :omit

      Corvid.adapter.add_referral(referral.referral_identifier, **adapter_attrs)
      referral
    end
  end
end
