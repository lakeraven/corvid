# frozen_string_literal: true

require "test_helper"

class Corvid::BillingTransactionTest < ActiveSupport::TestCase
  TENANT = "tnt_bt_test"

  setup do
    Corvid::BillingTransaction.unscoped.delete_all
  end

  test "log_transaction! creates a record" do
    with_tenant(TENANT) do
      tx = Corvid::BillingTransaction.log_transaction!(
        tenant: TENANT, type: "eligibility", direction: "outbound",
        status: "completed"
      )
      assert tx.persisted?
      assert_equal "eligibility", tx.transaction_type
      assert_equal "outbound", tx.direction
    end
  end

  test "validates transaction_type" do
    with_tenant(TENANT) do
      tx = Corvid::BillingTransaction.new(transaction_type: "bogus", direction: "outbound")
      refute tx.valid?
    end
  end

  test "validates direction" do
    with_tenant(TENANT) do
      tx = Corvid::BillingTransaction.new(transaction_type: "eligibility", direction: "bogus")
      refute tx.valid?
    end
  end

  test "by_type scope" do
    with_tenant(TENANT) do
      elig = Corvid::BillingTransaction.log_transaction!(tenant: TENANT, type: "eligibility", direction: "outbound")
      claim = Corvid::BillingTransaction.log_transaction!(tenant: TENANT, type: "claim", direction: "outbound")

      assert_includes Corvid::BillingTransaction.by_type("eligibility"), elig
      refute_includes Corvid::BillingTransaction.by_type("eligibility"), claim
    end
  end

  test "recent scope orders by created_at desc" do
    with_tenant(TENANT) do
      old = Corvid::BillingTransaction.log_transaction!(tenant: TENANT, type: "eligibility", direction: "outbound")
      new_tx = Corvid::BillingTransaction.log_transaction!(tenant: TENANT, type: "claim", direction: "outbound")

      assert_equal new_tx, Corvid::BillingTransaction.recent.first
    end
  end

  # -- Defaults --------------------------------------------------------------

  test "defaults direction to outbound" do
    with_tenant(TENANT) do
      tx = Corvid::BillingTransaction.new(transaction_type: "eligibility")
      assert_equal "outbound", tx.direction
    end
  end

  test "defaults status to pending" do
    with_tenant(TENANT) do
      # BillingTransaction has default status "pending" in DB
      tx = Corvid::BillingTransaction.new(transaction_type: "eligibility")
      assert_equal "pending", tx.status
    end
  end

  # -- More scopes -----------------------------------------------------------

  test "by_direction scope" do
    with_tenant(TENANT) do
      outbound = Corvid::BillingTransaction.log_transaction!(
        tenant: TENANT, type: "eligibility", direction: "outbound"
      )
      inbound = Corvid::BillingTransaction.log_transaction!(
        tenant: TENANT, type: "eligibility", direction: "inbound"
      )

      assert_includes Corvid::BillingTransaction.by_direction("outbound"), outbound
      refute_includes Corvid::BillingTransaction.by_direction("outbound"), inbound
    end
  end

  test "by_status scope" do
    with_tenant(TENANT) do
      completed = Corvid::BillingTransaction.log_transaction!(
        tenant: TENANT, type: "eligibility", direction: "outbound", status: "completed"
      )
      failed_tx = Corvid::BillingTransaction.log_transaction!(
        tenant: TENANT, type: "eligibility", direction: "outbound", status: "failed"
      )

      assert_includes Corvid::BillingTransaction.by_status("completed"), completed
      refute_includes Corvid::BillingTransaction.by_status("completed"), failed_tx
    end
  end

  test "for_patient scope" do
    with_tenant(TENANT) do
      mine = Corvid::BillingTransaction.log_transaction!(
        tenant: TENANT, type: "eligibility", direction: "outbound", patient: "pt_1"
      )
      other = Corvid::BillingTransaction.log_transaction!(
        tenant: TENANT, type: "eligibility", direction: "outbound", patient: "pt_2"
      )

      assert_includes Corvid::BillingTransaction.for_patient("pt_1"), mine
      refute_includes Corvid::BillingTransaction.for_patient("pt_1"), other
    end
  end

  # -- Instance methods ------------------------------------------------------

  test "success? returns true when status is completed" do
    with_tenant(TENANT) do
      tx = Corvid::BillingTransaction.new(status: "completed")
      assert tx.success?
    end
  end

  test "failed? returns true when status is failed" do
    with_tenant(TENANT) do
      tx = Corvid::BillingTransaction.new(status: "failed")
      assert tx.failed?
    end
  end

  test "pending? returns true when status is pending" do
    with_tenant(TENANT) do
      tx = Corvid::BillingTransaction.new(status: "pending")
      assert tx.pending?
    end
  end

  test "eligibility? returns true for eligibility type" do
    with_tenant(TENANT) do
      tx = Corvid::BillingTransaction.new(transaction_type: "eligibility")
      assert tx.eligibility?
    end
  end

  test "claim? returns true for claim type" do
    with_tenant(TENANT) do
      tx = Corvid::BillingTransaction.new(transaction_type: "claim")
      assert tx.claim?
    end
  end

  test "mark_success! updates status" do
    with_tenant(TENANT) do
      tx = Corvid::BillingTransaction.log_transaction!(
        tenant: TENANT, type: "eligibility", direction: "outbound", status: "pending"
      )
      tx.mark_success!(response_token: "resp_123")
      assert_equal "completed", tx.reload.status
      assert_equal "resp_123", tx.response_token
    end
  end

  test "mark_error! updates status and error message" do
    with_tenant(TENANT) do
      tx = Corvid::BillingTransaction.log_transaction!(
        tenant: TENANT, type: "eligibility", direction: "outbound", status: "pending"
      )
      tx.mark_error!("Subscriber not found")
      assert_equal "failed", tx.reload.status
      assert_equal "Subscriber not found", tx.error_message
    end
  end

  # -- Statistics ------------------------------------------------------------

  test "success_rate calculates percentage" do
    with_tenant(TENANT) do
      3.times { Corvid::BillingTransaction.log_transaction!(tenant: TENANT, type: "eligibility", direction: "outbound", status: "completed") }
      1.times { Corvid::BillingTransaction.log_transaction!(tenant: TENANT, type: "eligibility", direction: "outbound", status: "failed") }

      rate = Corvid::BillingTransaction.success_rate
      assert_equal 75.0, rate
    end
  end

  test "success_rate returns 0 when no transactions" do
    with_tenant(TENANT) do
      assert_equal 0, Corvid::BillingTransaction.success_rate
    end
  end

  test "by_type_counts groups by transaction_type" do
    with_tenant(TENANT) do
      2.times { Corvid::BillingTransaction.log_transaction!(tenant: TENANT, type: "eligibility", direction: "outbound") }
      3.times { Corvid::BillingTransaction.log_transaction!(tenant: TENANT, type: "claim", direction: "outbound") }

      counts = Corvid::BillingTransaction.by_type_counts
      assert_equal 2, counts["eligibility"]
      assert_equal 3, counts["claim"]
    end
  end

  # -- TRANSACTION_TYPES constant -------------------------------------------

  test "accepts all valid transaction types" do
    with_tenant(TENANT) do
      Corvid::BillingTransaction::TRANSACTION_TYPES.each do |type|
        tx = Corvid::BillingTransaction.new(transaction_type: type, direction: "outbound")
        tx.valid?
        refute_includes tx.errors[:transaction_type], "is not included in the list"
      end
    end
  end
end
