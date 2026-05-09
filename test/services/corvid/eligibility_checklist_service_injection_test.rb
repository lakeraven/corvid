# frozen_string_literal: true

require "test_helper"

# Per #222 / ADR 0005: EligibilityChecklistService accepts an
# `adapter:` kwarg so per-tenant enrollment/insurance verification
# routes through the right backend without mutating the global
# Corvid.adapter.
class Corvid::EligibilityChecklistServiceInjectionTest < ActiveSupport::TestCase
  TENANT = "tnt_elig_inject"
  FACILITY = "fac_elig_inject"

  # Recording fake — every adapter call lands here so we can assert
  # routing went through the injected adapter.
  class RecordingAdapter
    attr_reader :calls

    def initialize(coverages: [ { plan: "Test" } ])
      @calls = []
      @coverages = coverages
    end

    def verify_tribal_enrollment(patient_id)
      @calls << [ :verify_tribal_enrollment, patient_id ]
      { enrolled: true }
    end

    def verify_identity_documents(patient_id)
      @calls << [ :verify_identity_documents, patient_id ]
      { ssn_present: true, dob_present: true }
    end

    def verify_residency(patient_id)
      @calls << [ :verify_residency, patient_id ]
      { on_reservation: true }
    end

    def get_coverages(patient_id)
      @calls << [ :get_coverages, patient_id ]
      @coverages
    end
  end

  setup do
    @fake = RecordingAdapter.new
    @original_adapter = Corvid.adapter
  end

  teardown do
    Corvid.configure { |c| c.adapter = @original_adapter }
  end

  test "instance#populate! routes every verification call through the injected adapter" do
    Corvid.configure { |c| c.adapter = poison_adapter }
    Corvid::TenantContext.with_tenant(TENANT) do
      referral = build_referral_in_tenant
      service = Corvid::EligibilityChecklistService.new(adapter: @fake)

      service.populate!(referral)

      checklist = referral.reload.eligibility_checklist
      assert checklist.enrollment_verified
      assert checklist.identity_verified
      assert checklist.residency_verified
      assert checklist.insurance_verified

      methods_called = @fake.calls.map(&:first).uniq.sort
      assert_equal %i[get_coverages verify_identity_documents verify_residency verify_tribal_enrollment].sort,
                   methods_called
    end
  end

  test "instance#check_payer_eligibility! routes get_coverages through the injected adapter" do
    Corvid.configure { |c| c.adapter = poison_adapter }
    Corvid::TenantContext.with_tenant(TENANT) do
      referral = build_referral_with_checklist_in_tenant
      service = Corvid::EligibilityChecklistService.new(adapter: @fake)

      service.check_payer_eligibility!(referral)

      assert_includes @fake.calls.map(&:first), :get_coverages
      assert referral.reload.eligibility_checklist.insurance_verified
    end
  end

  test "class .populate! accepts adapter: kwarg without touching the global" do
    Corvid.configure { |c| c.adapter = poison_adapter }
    Corvid::TenantContext.with_tenant(TENANT) do
      referral = build_referral_in_tenant
      Corvid::EligibilityChecklistService.populate!(referral, adapter: @fake)
      assert_includes @fake.calls.map(&:first), :verify_tribal_enrollment
    end
  end

  test "class .populate! without kwarg falls back to Corvid.adapter (backward-compat)" do
    Corvid.configure { |c| c.adapter = @fake }
    Corvid::TenantContext.with_tenant(TENANT) do
      referral = build_referral_in_tenant
      Corvid::EligibilityChecklistService.populate!(referral)
      assert_includes @fake.calls.map(&:first), :verify_tribal_enrollment
    end
  end

  test "class .check_payer_eligibility!(adapter:) routes through the injected adapter via shim" do
    Corvid.configure { |c| c.adapter = poison_adapter }
    Corvid::TenantContext.with_tenant(TENANT) do
      referral = build_referral_with_checklist_in_tenant
      Corvid::EligibilityChecklistService.check_payer_eligibility!(referral, adapter: @fake)
      assert_includes @fake.calls.map(&:first), :get_coverages
    end
  end

  # -- Edge case: degraded adapter response ----------------------------------

  class EmptyCoveragesAdapter < RecordingAdapter
    def initialize
      super(coverages: [])
    end
  end

  # Adapter that returns nil instead of the expected hash/array shapes.
  # Reaching across a network or backend boundary can legitimately
  # produce nil on lookup miss; the service must not crash.
  class NilReturnAdapter
    def verify_tribal_enrollment(_id);      nil; end
    def verify_identity_documents(_id);     nil; end
    def verify_residency(_id);              nil; end
    def get_coverages(_id);                 nil; end
  end

  test "populate! with nil adapter returns leaves checklist items unverified instead of raising" do
    Corvid::TenantContext.with_tenant(TENANT) do
      referral = build_referral_in_tenant
      service = Corvid::EligibilityChecklistService.new(adapter: NilReturnAdapter.new)

      assert_nothing_raised { service.populate!(referral) }

      checklist = referral.reload.eligibility_checklist
      refute checklist.enrollment_verified
      refute checklist.identity_verified
      refute checklist.residency_verified
      refute checklist.insurance_verified
    end
  end

  test "check_payer_eligibility! with empty coverages does not flip insurance_verified" do
    Corvid::TenantContext.with_tenant(TENANT) do
      referral = build_referral_with_checklist_in_tenant
      service = Corvid::EligibilityChecklistService.new(adapter: EmptyCoveragesAdapter.new)
      service.check_payer_eligibility!(referral)
      refute referral.reload.eligibility_checklist.insurance_verified
    end
  end

  private

  # Helpers must be called from within `Corvid::TenantContext.with_tenant`
  # — TenantScoped's default_scope raises if no tenant is set.
  def build_referral_in_tenant
    Corvid::PrcReferral.create!(
      case: Corvid::Case.create!(patient_identifier: "p_elig", facility_identifier: FACILITY),
      referral_identifier: "rf_elig_#{SecureRandom.hex(4)}",
      facility_identifier: FACILITY
    )
  end

  def build_referral_with_checklist_in_tenant
    referral = build_referral_in_tenant
    referral.create_eligibility_checklist!(
      tenant_identifier: TENANT, facility_identifier: FACILITY
    )
    referral
  end

  def poison_adapter
    Object.new.tap do |o|
      def o.method_missing(name, *_a, **_kw)
        raise "Corvid.adapter (the global) was used unexpectedly: ##{name}"
      end

      def o.respond_to_missing?(_n, _p = false); true; end
    end
  end
end
