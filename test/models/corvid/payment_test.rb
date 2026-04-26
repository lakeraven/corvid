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

    test "pending → processing" do
      @payment.begin_processing!
      update_identifier("pi_123")
      assert @payment.processing?
    end

    test "processing → succeeded" do
      @payment.begin_processing!
      @payment.confirm_succeeded!(receipt_url: "https://stripe.com/receipt/123")
      assert @payment.succeeded?
      assert_equal "https://stripe.com/receipt/123", @payment.receipt_url
    end

    test "pending → failed" do
      @payment.confirm_failed!
      assert @payment.failed?
    end

    test "processing → failed" do
      @payment.begin_processing!
      @payment.confirm_failed!
      assert @payment.failed?
    end

    test "succeeded → refunded" do
      move_to_succeeded!
      @payment.mark_refunded!
      assert @payment.refunded?
    end

    # -- State machine: invalid transitions -----------------------------------

    test "cannot refund a pending payment" do
      assert_raises(AASM::InvalidTransition) { @payment.mark_refunded! }
    end

    test "cannot mark succeeded from pending" do
      assert_raises(AASM::InvalidTransition) { @payment.mark_succeeded! }
    end

    test "cannot begin processing from succeeded" do
      move_to_succeeded!
      assert_raises(AASM::InvalidTransition) { @payment.begin_processing! }
    end

    # -- Predicates -----------------------------------------------------------

    test "refundable? true for succeeded with payment_identifier" do
      move_to_succeeded!
      assert @payment.refundable?
    end

    test "refundable? false for pending" do
      assert_not @payment.refundable?
    end

    test "refundable? false for already refunded" do
      move_to_succeeded!
      @payment.mark_refunded!
      assert_not @payment.refundable?
    end

    # -- Scopes ---------------------------------------------------------------

    test "succeeded scope" do
      move_to_succeeded!
      assert_includes Payment.succeeded, @payment
    end

    test "for_patient scope" do
      assert_includes Payment.for_patient("pt_1"), @payment
      assert_empty Payment.for_patient("pt_999")
    end

    # -- Status validation ----------------------------------------------------

    test "status must be valid" do
      p = Payment.new(patient_identifier: "pt_1", amount_cents: 5000, status: "bogus")
      assert_not p.valid?
      assert p.errors[:status].any?
    end

    # -- Total collected ------------------------------------------------------

    test "total_collected sums succeeded payments" do
      Payment.create!(patient_identifier: "pt_tc", amount_cents: 5000, status: "succeeded")
      Payment.create!(patient_identifier: "pt_tc", amount_cents: 3000, status: "succeeded")
      Payment.create!(patient_identifier: "pt_tc", amount_cents: 2000, status: "failed")

      assert_equal 80.0, Payment.total_collected
    end

    # -- Refundable? edge cases -----------------------------------------------

    test "refundable? false for succeeded without payment_identifier" do
      move_to_succeeded!
      @payment.update_column(:payment_identifier, nil)
      assert_not @payment.refundable?
    end

    # -- Additional state transitions -----------------------------------------

    test "processing? returns true when processing" do
      @payment.begin_processing!
      assert @payment.processing?
    end

    test "succeeded? returns true when succeeded" do
      move_to_succeeded!
      assert @payment.succeeded?
    end

    test "refunded? returns true when refunded" do
      move_to_succeeded!
      @payment.mark_refunded!
      assert @payment.refunded?
    end

    private

    def move_to_succeeded!
      @payment.begin_processing!
      @payment.update!(payment_identifier: "pi_123")
      @payment.mark_succeeded!
    end

    def update_identifier(id)
      @payment.update!(payment_identifier: id)
    end
  end
end
