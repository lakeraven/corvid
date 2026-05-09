# frozen_string_literal: true

require "test_helper"

# Per #222 / ADR 0005: BudgetAvailabilityService accepts an `adapter:`
# kwarg so per-tenant budget routing and per-test fakes can be
# injected without mutating the global Corvid.adapter.
class Corvid::BudgetAvailabilityServiceInjectionTest < ActiveSupport::TestCase
  TENANT = "tnt_budget_inject"

  # Minimal recording fake — every adapter call lands here so we can
  # assert routing went through the injected adapter rather than the
  # global.
  class RecordingAdapter
    attr_reader :calls

    def initialize
      @calls = []
    end

    def get_budget_summary
      @calls << [ :get_budget_summary ]
      { total_budget: 1_000_000.0, obligated: 100_000.0, remaining: 900_000.0 }
    end

    def create_obligation(referral_identifier, amount, params = {})
      @calls << [ :create_obligation, referral_identifier, amount, params ]
      Object.new.tap do |o|
        def o.success?; true; end
        def o.failure?; false; end
        def o.id; "obl_inj"; end
      end
    end
  end

  setup do
    @fake = RecordingAdapter.new
    @original_adapter = Corvid.adapter
  end

  teardown do
    Corvid.configure { |c| c.adapter = @original_adapter }
  end

  test "instance routes get_budget_summary through the injected adapter" do
    Corvid.configure { |c| c.adapter = poison_adapter }
    service = Corvid::BudgetAvailabilityService.new(adapter: @fake)

    assert_equal 900_000.0, service.remaining_budget
    assert_equal 100_000.0, service.reserved_funds
    assert_equal 1_000_000.0, service.fiscal_year_budget
    assert_includes @fake.calls.map(&:first), :get_budget_summary
  end

  test "instance routes create_obligation through the injected adapter" do
    Corvid.configure { |c| c.adapter = poison_adapter }
    service = Corvid::BudgetAvailabilityService.new(adapter: @fake)

    service.reserve_funds_if_available("rf_inj", 5_000)

    assert_equal :create_obligation, @fake.calls.last[0]
    assert_equal "rf_inj", @fake.calls.last[1]
  end

  test "class method accepts adapter: kwarg without touching the global" do
    Corvid.configure { |c| c.adapter = poison_adapter }

    Corvid::BudgetAvailabilityService.reserve_funds_if_available("rf_cls", 1_000, {}, adapter: @fake)

    assert_equal :create_obligation, @fake.calls.last[0]
  end

  test "class .remaining_budget without kwarg falls back to Corvid.adapter (backward-compat)" do
    Corvid.configure { |c| c.adapter = @fake }

    Corvid::BudgetAvailabilityService.remaining_budget

    assert_includes @fake.calls.map(&:first), :get_budget_summary
  end

  test "check(referral) routes through the injected adapter for budget figures" do
    Corvid.configure { |c| c.adapter = poison_adapter }
    Corvid::TenantContext.with_tenant(TENANT) do
      ref = Corvid::PrcReferral.create!(
        case: Corvid::Case.create!(patient_identifier: "p_b", facility_identifier: "fac_b"),
        referral_identifier: "rf_check_#{SecureRandom.hex(4)}",
        estimated_cost_cents: 10_000,
        currency_iso: "USD"
      )

      result = Corvid::BudgetAvailabilityService.new(adapter: @fake).check(ref)

      assert_equal 900_000.0, result.remaining_budget
      assert_includes @fake.calls.map(&:first), :get_budget_summary
    end
  end

  test "class .check(referral, adapter:) routes through the injected adapter via shim" do
    Corvid.configure { |c| c.adapter = poison_adapter }
    Corvid::TenantContext.with_tenant(TENANT) do
      ref = Corvid::PrcReferral.create!(
        case: Corvid::Case.create!(patient_identifier: "p_cs", facility_identifier: "fac_cs"),
        referral_identifier: "rf_classcheck_#{SecureRandom.hex(4)}",
        estimated_cost_cents: 50_000_00, # 50_000 USD — at the committee threshold
        currency_iso: "USD"
      )

      result = Corvid::BudgetAvailabilityService.check(ref, adapter: @fake)

      assert_equal 900_000.0, result.remaining_budget
      assert result.requires_committee_review,
             "50_000 USD is at COMMITTEE_REVIEW_THRESHOLD"
      assert_includes @fake.calls.map(&:first), :get_budget_summary
    end
  end

  # -- Edge cases: degraded adapter responses --------------------------------

  class NilSummaryAdapter
    def get_budget_summary; nil; end
  end

  class EmptySummaryAdapter
    def get_budget_summary; {}; end
  end

  test "remaining_budget falls back to 0.0 when adapter returns nil" do
    service = Corvid::BudgetAvailabilityService.new(adapter: NilSummaryAdapter.new)
    assert_equal 0.0, service.remaining_budget
    assert_equal 0.0, service.reserved_funds
  end

  test "fiscal_year_budget falls back to default when adapter returns nil" do
    service = Corvid::BudgetAvailabilityService.new(adapter: NilSummaryAdapter.new)
    assert_equal Corvid::BudgetAvailabilityService::DEFAULT_FISCAL_YEAR_BUDGET,
                 service.fiscal_year_budget
  end

  test "fiscal_year_budget falls back to default when adapter returns an empty payload" do
    service = Corvid::BudgetAvailabilityService.new(adapter: EmptySummaryAdapter.new)
    assert_equal Corvid::BudgetAvailabilityService::DEFAULT_FISCAL_YEAR_BUDGET,
                 service.fiscal_year_budget
    assert_equal 0.0, service.remaining_budget
    assert_equal 0.0, service.reserved_funds
  end

  private

  def poison_adapter
    Object.new.tap do |o|
      def o.method_missing(name, *_a, **_kw)
        raise "Corvid.adapter (the global) was used unexpectedly: ##{name}"
      end

      def o.respond_to_missing?(_n, _p = false); true; end
    end
  end
end
