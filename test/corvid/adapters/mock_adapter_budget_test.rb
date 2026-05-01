# frozen_string_literal: true

require "test_helper"

class Corvid::Adapters::MockAdapterBudgetTest < ActiveSupport::TestCase
  setup do
    @adapter = Corvid::Adapters::MockAdapter.new
  end

  # =============================================================================
  # GET BUDGET SUMMARY
  # =============================================================================

  test "get_budget_summary returns comprehensive budget overview" do
    summary = @adapter.get_budget_summary

    assert summary.is_a?(Hash)
    assert summary.key?(:fiscal_year)
    assert summary.key?(:total_budget)
    assert summary.key?(:obligated)
    assert summary.key?(:expended)
    assert summary.key?(:remaining)
    assert summary.key?(:percent_remaining)
  end

  test "get_budget_summary returns positive total_budget" do
    summary = @adapter.get_budget_summary
    assert summary[:total_budget] > 0
  end

  test "get_budget_summary includes quarterly breakdown" do
    summary = @adapter.get_budget_summary
    assert summary.key?(:quarters)
  end

  # =============================================================================
  # CREATE OBLIGATION
  # =============================================================================

  test "create_obligation reserves funds for referral" do
    result = @adapter.create_obligation("REF-001", 10_000.00)

    assert result.success?
    assert result.id.present?
  end

  test "create_obligation fails when amount is absurdly large" do
    result = @adapter.create_obligation("REF-002", 999_999_999_999.00)

    assert result.failure?
    assert_match(/insufficient/i, result.message)
  end

  test "create_obligation stores obligation data" do
    result = @adapter.create_obligation("REF-003", 5_000.00, service_type: "Lab")

    obligation = @adapter.get_obligation(result.id)
    assert_equal "REF-003", obligation[:referral_ien]
    assert_equal 5_000.00, obligation[:amount]
    assert_equal "PENDING", obligation[:status]
  end

  # =============================================================================
  # RELEASE OBLIGATION
  # =============================================================================

  test "release_obligation frees reserved funds" do
    create_result = @adapter.create_obligation("REF-004", 5_000.00)
    result = @adapter.release_obligation(create_result.id)

    assert result.success?
  end

  test "release_obligation updates status to RELEASED" do
    create_result = @adapter.create_obligation("REF-005", 5_000.00)
    @adapter.release_obligation(create_result.id)

    obligation = @adapter.get_obligation(create_result.id)
    assert_equal "RELEASED", obligation[:status]
  end

  test "release_obligation fails for non-existent obligation" do
    result = @adapter.release_obligation("NONEXISTENT")

    assert result.failure?
  end

  # =============================================================================
  # GET OBLIGATION
  # =============================================================================

  test "get_obligation returns obligation details by ID" do
    create_result = @adapter.create_obligation("REF-006", 8_000.00)
    obligation = @adapter.get_obligation(create_result.id)

    assert obligation.is_a?(Hash)
    assert_equal create_result.id, obligation[:id]
    assert_equal 8_000.00, obligation[:amount]
    assert_equal "REF-006", obligation[:referral_ien]
  end

  test "get_obligation returns nil for non-existent obligation" do
    assert_nil @adapter.get_obligation("NONEXISTENT")
  end

  # =============================================================================
  # GET OBLIGATION BY REFERRAL
  # =============================================================================

  test "get_obligation_by_referral finds obligation for referral" do
    @adapter.create_obligation("REF-007", 12_000.00)
    obligation = @adapter.get_obligation_by_referral("REF-007")

    assert obligation.is_a?(Hash)
    assert_equal "REF-007", obligation[:referral_ien]
  end

  test "get_obligation_by_referral returns nil when no obligation exists" do
    assert_nil @adapter.get_obligation_by_referral("REF-NONE")
  end

  # =============================================================================
  # RECORD PAYMENT
  # =============================================================================

  test "record_payment creates payment for obligation" do
    create_result = @adapter.create_obligation("REF-008", 10_000.00)
    result = @adapter.record_payment(
      obligation_id: create_result.id,
      amount: 4_500.00,
      payment_date: Date.current,
      check_number: "CHK-12345"
    )

    assert result.success?
    assert result.id.present?
  end

  test "record_payment fails for non-existent obligation" do
    result = @adapter.record_payment(obligation_id: "NONEXISTENT", amount: 1_000.00)

    assert result.failure?
  end

  test "record_payment fails when amount exceeds obligation" do
    create_result = @adapter.create_obligation("REF-009", 5_000.00)
    result = @adapter.record_payment(obligation_id: create_result.id, amount: 999_999.00)

    assert result.failure?
    assert_match(/exceeds/i, result.message)
  end

  test "record_payment reduces amount_due" do
    create_result = @adapter.create_obligation("REF-010", 10_000.00)
    @adapter.record_payment(obligation_id: create_result.id, amount: 3_000.00)

    obligation = @adapter.get_obligation(create_result.id)
    assert_equal 7_000.00, obligation[:amount_due]
  end

  test "record_payment marks obligation PAID when fully paid" do
    create_result = @adapter.create_obligation("REF-011", 5_000.00)
    @adapter.record_payment(obligation_id: create_result.id, amount: 5_000.00)

    obligation = @adapter.get_obligation(create_result.id)
    assert_equal "PAID", obligation[:status]
  end

  # =============================================================================
  # GET PAYMENTS
  # =============================================================================

  test "get_payments returns payments for obligation" do
    create_result = @adapter.create_obligation("REF-012", 10_000.00)
    @adapter.record_payment(obligation_id: create_result.id, amount: 3_000.00)
    @adapter.record_payment(obligation_id: create_result.id, amount: 2_000.00)

    payments = @adapter.get_payments(obligation_id: create_result.id)
    assert_equal 2, payments.length
  end

  test "get_payments returns empty array for obligation with no payments" do
    create_result = @adapter.create_obligation("REF-013", 5_000.00)
    payments = @adapter.get_payments(obligation_id: create_result.id)

    assert_equal [], payments
  end

  # =============================================================================
  # UPDATE OBLIGATION STATUS
  # =============================================================================

  test "update_obligation_status marks obligation as PAID" do
    create_result = @adapter.create_obligation("REF-014", 5_000.00)
    result = @adapter.update_obligation_status(create_result.id, status: "PAID")

    assert result.success?
    assert_equal "PAID", @adapter.get_obligation(create_result.id)[:status]
  end

  test "update_obligation_status marks obligation as CANCELLED" do
    create_result = @adapter.create_obligation("REF-015", 5_000.00)
    result = @adapter.update_obligation_status(create_result.id, status: "CANCELLED")

    assert result.success?
    assert_equal "CANCELLED", @adapter.get_obligation(create_result.id)[:status]
  end

  test "update_obligation_status fails for invalid status" do
    create_result = @adapter.create_obligation("REF-016", 5_000.00)
    result = @adapter.update_obligation_status(create_result.id, status: "INVALID")

    assert result.failure?
  end

  test "update_obligation_status fails for non-existent obligation" do
    result = @adapter.update_obligation_status("NONEXISTENT", status: "PAID")

    assert result.failure?
  end

  # =============================================================================
  # GET OUTSTANDING OBLIGATIONS
  # =============================================================================

  test "get_outstanding_obligations returns unpaid obligations" do
    @adapter.create_obligation("REF-017", 5_000.00)
    @adapter.create_obligation("REF-018", 3_000.00)

    obligations = @adapter.get_outstanding_obligations
    assert_equal 2, obligations.length
    obligations.each { |o| assert_equal "PENDING", o[:status] }
  end

  test "get_outstanding_obligations excludes paid obligations" do
    result1 = @adapter.create_obligation("REF-019", 5_000.00)
    @adapter.create_obligation("REF-020", 3_000.00)
    @adapter.update_obligation_status(result1.id, status: "PAID")

    obligations = @adapter.get_outstanding_obligations
    assert_equal 1, obligations.length
  end

  # =============================================================================
  # OBLIGATION SUMMARY
  # =============================================================================

  test "get_obligation_summary returns totals" do
    result1 = @adapter.create_obligation("REF-021", 10_000.00)
    @adapter.create_obligation("REF-022", 5_000.00)
    @adapter.record_payment(obligation_id: result1.id, amount: 3_000.00)

    summary = @adapter.get_obligation_summary
    assert_equal 15_000.00, summary[:total_obligated]
    assert_equal 3_000.00, summary[:total_paid]
    assert_equal 12_000.00, summary[:total_outstanding]
    assert summary[:by_status].is_a?(Hash)
  end
end
