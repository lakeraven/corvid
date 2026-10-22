# frozen_string_literal: true

require "test_helper"

module Corvid
  # A bang event on a record that fails validation returns false and leaves
  # the persisted state alone; it does not raise. aasm 6 flipped the
  # whiny_persistence default to true, so both machines pin it explicitly to
  # keep this contract independent of which aasm major resolves.
  class AasmPersistenceContractTest < ActiveSupport::TestCase
    TENANT = "tnt_aasm_contract"
    FACILITY = "fac_aasm_contract"

    test "PrcReferral bang event on an invalid record returns false without raising" do
      with_tenant(TENANT) do
        kase = Case.create!(patient_identifier: "pt_test_001", facility_identifier: FACILITY)
        referral = PrcReferral.create!(
          case: kase,
          referral_identifier: "rf_#{SecureRandom.hex(4)}",
          facility_identifier: FACILITY,
          estimated_cost: 5_000
        )
        referral.referral_identifier = nil

        result = nil
        assert_nothing_raised { result = referral.cancel! }
        refute result, "expected cancel! on an invalid referral to return false"
        assert_equal "draft", referral.reload.status
      end
    end

    test "Payment bang event on an invalid record returns false without raising" do
      with_tenant(TENANT) do
        payment = Payment.create!(patient_identifier: "pt_test_001", amount_cents: 5000)
        payment.amount_cents = 0

        result = nil
        assert_nothing_raised { result = payment.begin_processing! }
        refute result, "expected begin_processing! on an invalid payment to return false"
        assert_equal "pending", payment.reload.status
      end
    end
  end
end
