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
end
