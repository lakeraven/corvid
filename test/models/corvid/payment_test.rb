# frozen_string_literal: true

require "test_helper"

module Corvid
  class PaymentTest < ActiveSupport::TestCase
    setup do
      Corvid.current_tenant_identifier = "tnt_test"
      @payment = Payment.create!(
        patient_identifier: "pt_1",
        amount_cents: 5000,
        description: "Office visit copay"
      )
    end

    teardown do
      Corvid.current_tenant_identifier = nil
    end

    # -- Basics ---------------------------------------------------------------

    test "defaults status to pending" do
      assert @payment.pending?
    end

    test "amount_dollars converts cents" do
      assert_in_delta 50.0, @payment.amount_dollars
    end

    test "validates amount_cents positive" do
      p = Payment.new(patient_identifier: "pt_1", amount_cents: 0)
      assert_not p.valid?
    end

    test "validates patient_identifier presence" do
      p = Payment.new(amount_cents: 100)
      assert_not p.valid?
    end

    # -- State machine: valid transitions -------------------------------------

    test "pending → processing via mark_processing!" do
      @payment.mark_processing!(payment_identifier: "pi_123")
      assert @payment.processing?
      assert_equal "pi_123", @payment.payment_identifier
    end

    test "processing → succeeded via mark_succeeded!" do
      @payment.mark_processing!(payment_identifier: "pi_123")
      @payment.mark_succeeded!(receipt_url: "https://stripe.com/receipt/123")
      assert @payment.succeeded?
      assert_equal "https://stripe.com/receipt/123", @payment.receipt_url
    end

    test "pending → failed via mark_failed!" do
      @payment.mark_failed!(message: "Card declined")
      assert @payment.failed?
    end

    test "processing → failed via mark_failed!" do
      @payment.mark_processing!(payment_identifier: "pi_123")
      @payment.mark_failed!(message: "Timeout")
      assert @payment.failed?
    end

    test "succeeded → refunded via mark_refunded!" do
      @payment.mark_processing!(payment_identifier: "pi_123")
      @payment.mark_succeeded!
      @payment.mark_refunded!
      assert @payment.refunded?
    end

    # -- State machine: invalid transitions -----------------------------------

    test "cannot refund a pending payment" do
      assert_raises(AASM::InvalidTransition) { @payment.mark_refunded! }
    end

    test "cannot succeed a pending payment" do
      assert_raises(AASM::InvalidTransition) { @payment.mark_succeeded! }
    end

    test "cannot process an already succeeded payment" do
      @payment.mark_processing!(payment_identifier: "pi_123")
      @payment.mark_succeeded!
      assert_raises(AASM::InvalidTransition) { @payment.mark_processing!(payment_identifier: "pi_456") }
    end

    # -- Predicates -----------------------------------------------------------

    test "refundable? true for succeeded with payment_identifier" do
      @payment.mark_processing!(payment_identifier: "pi_123")
      @payment.mark_succeeded!
      assert @payment.refundable?
    end

    test "refundable? false for pending" do
      assert_not @payment.refundable?
    end

    test "refundable? false for already refunded" do
      @payment.mark_processing!(payment_identifier: "pi_123")
      @payment.mark_succeeded!
      @payment.mark_refunded!
      assert_not @payment.refundable?
    end

    # -- Scopes ---------------------------------------------------------------

    test "succeeded scope" do
      @payment.mark_processing!(payment_identifier: "pi_123")
      @payment.mark_succeeded!
      assert_includes Payment.succeeded, @payment
    end

    test "for_patient scope" do
      assert_includes Payment.for_patient("pt_1"), @payment
      assert_empty Payment.for_patient("pt_999")
    end
  end
end
