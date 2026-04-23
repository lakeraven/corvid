# frozen_string_literal: true

require "test_helper"

class Corvid::BillingTransactionTest < ActiveSupport::TestCase
  TENANT = "tnt_bt_test"

  setup do
    Corvid::BillingTransaction.unscoped.delete_all
  end

  # =============================================================================
  # CREATION
  # =============================================================================

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

  test "log_transaction! stores all fields" do
    with_tenant(TENANT) do
      tx = Corvid::BillingTransaction.log_transaction!(
        tenant: TENANT,
        facility: "fac_test",
        type: "claim",
        direction: "outbound",
        reference: "claim_123",
        patient: "pt_1",
        request_token: "req_tok",
        response_token: "resp_tok",
        status: "completed"
      )
      assert_equal "fac_test", tx.facility_identifier
      assert_equal "claim_123", tx.reference_identifier
      assert_equal "pt_1", tx.patient_identifier
      assert_equal "req_tok", tx.request_token
      assert_equal "resp_tok", tx.response_token
    end
  end

  test "log_transaction! stores error message" do
    with_tenant(TENANT) do
      tx = Corvid::BillingTransaction.log_transaction!(
        tenant: TENANT, type: "eligibility", direction: "outbound",
        status: "failed", error: "Connection timeout"
      )
      assert_equal "failed", tx.status
      assert_equal "Connection timeout", tx.error_message
    end
  end

  test "defaults status to pending" do
    with_tenant(TENANT) do
      tx = Corvid::BillingTransaction.create!(
        transaction_type: "eligibility",
        direction: "outbound"
      )
      assert_equal "pending", tx.status
    end
  end

  test "defaults direction to outbound" do
    with_tenant(TENANT) do
      tx = Corvid::BillingTransaction.create!(
        transaction_type: "eligibility"
      )
      assert_equal "outbound", tx.direction
    end
  end

  # =============================================================================
  # VALIDATIONS
  # =============================================================================

  test "requires transaction_type" do
    with_tenant(TENANT) do
      tx = Corvid::BillingTransaction.new(direction: "outbound")
      refute tx.valid?
    end
  end

  test "transaction_type must be valid" do
    with_tenant(TENANT) do
      tx = Corvid::BillingTransaction.new(transaction_type: "bogus", direction: "outbound")
      refute tx.valid?
    end
  end

  test "accepts all valid transaction types" do
    with_tenant(TENANT) do
      Corvid::BillingTransaction::TRANSACTION_TYPES.each do |type|
        tx = Corvid::BillingTransaction.new(transaction_type: type, direction: "outbound")
        assert tx.valid?, "Should accept type: #{type}"
      end
    end
  end

  test "direction must be valid" do
    with_tenant(TENANT) do
      tx = Corvid::BillingTransaction.new(transaction_type: "eligibility", direction: "bogus")
      refute tx.valid?
    end
  end

  test "accepts inbound direction" do
    with_tenant(TENANT) do
      tx = Corvid::BillingTransaction.new(transaction_type: "remittance", direction: "inbound")
      assert tx.valid?
    end
  end

  # =============================================================================
  # SCOPES
  # =============================================================================

  test "by_type scope" do
    with_tenant(TENANT) do
      elig = Corvid::BillingTransaction.log_transaction!(tenant: TENANT, type: "eligibility", direction: "outbound")
      claim = Corvid::BillingTransaction.log_transaction!(tenant: TENANT, type: "claim", direction: "outbound")

      assert_includes Corvid::BillingTransaction.by_type("eligibility"), elig
      refute_includes Corvid::BillingTransaction.by_type("eligibility"), claim
    end
  end

  test "by_direction scope" do
    with_tenant(TENANT) do
      outbound = Corvid::BillingTransaction.log_transaction!(tenant: TENANT, type: "eligibility", direction: "outbound")
      inbound = Corvid::BillingTransaction.log_transaction!(tenant: TENANT, type: "remittance", direction: "inbound")

      assert_includes Corvid::BillingTransaction.by_direction("outbound"), outbound
      refute_includes Corvid::BillingTransaction.by_direction("outbound"), inbound
    end
  end

  test "by_status scope" do
    with_tenant(TENANT) do
      completed = Corvid::BillingTransaction.log_transaction!(tenant: TENANT, type: "eligibility", direction: "outbound", status: "completed")
      failed = Corvid::BillingTransaction.log_transaction!(tenant: TENANT, type: "eligibility", direction: "outbound", status: "failed")

      assert_includes Corvid::BillingTransaction.by_status("completed"), completed
      refute_includes Corvid::BillingTransaction.by_status("completed"), failed
    end
  end

  test "for_patient scope" do
    with_tenant(TENANT) do
      mine = Corvid::BillingTransaction.log_transaction!(tenant: TENANT, type: "eligibility", direction: "outbound", patient: "pt_1")
      other = Corvid::BillingTransaction.log_transaction!(tenant: TENANT, type: "eligibility", direction: "outbound", patient: "pt_2")

      assert_includes Corvid::BillingTransaction.for_patient("pt_1"), mine
      refute_includes Corvid::BillingTransaction.for_patient("pt_1"), other
    end
  end

  test "recent scope orders by created_at desc" do
    with_tenant(TENANT) do
      _old = Corvid::BillingTransaction.log_transaction!(tenant: TENANT, type: "eligibility", direction: "outbound")
      new_tx = Corvid::BillingTransaction.log_transaction!(tenant: TENANT, type: "claim", direction: "outbound")

      assert_equal new_tx, Corvid::BillingTransaction.recent.first
    end
  end

  # =============================================================================
  # MULTI-TENANCY
  # =============================================================================

  test "transactions are scoped to tenant" do
    mine = nil
    other = nil

    with_tenant("tenant_a") do
      mine = Corvid::BillingTransaction.log_transaction!(tenant: "tenant_a", type: "eligibility", direction: "outbound")
    end

    with_tenant("tenant_b") do
      other = Corvid::BillingTransaction.log_transaction!(tenant: "tenant_b", type: "claim", direction: "outbound")
    end

    with_tenant("tenant_a") do
      assert_includes Corvid::BillingTransaction.all, mine
      refute_includes Corvid::BillingTransaction.all, other
    end
  end
end
