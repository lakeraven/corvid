# frozen_string_literal: true

require "test_helper"

# An adapter that cannot discover coverage must SAY so, rather than return
# an empty list that is indistinguishable from "this patient has no other
# coverage."
#
# The distinction matters for 42 CFR 136.61: PRC pays last. "We queried the
# payers and found nothing" authorizes payment. "We never asked" does not,
# and until now both produced the same `[]`.
#
# Corvid::Adapters::FhirAdapter — the only non-mock adapter shipped — does
# not override `get_coverages`, so it inherits Base's `[]` forever.
class Corvid::CoverageDiscoveryCapabilityTest < ActiveSupport::TestCase
  TENANT = "tnt_example"

  # An adapter that genuinely implements discovery.
  class DiscoveringAdapter < Corvid::Adapters::Base
    def get_coverages(_patient_identifier)
      [ { payer: "Example Health Plan", status: "active" } ]
    end
  end

  # An adapter that does not — it inherits Base's `get_coverages`.
  #
  # The other three verifications are implemented because Base *raises*
  # NotImplementedError for those (base.rb:25, :56, …) while `get_coverages`
  # silently returns `[]`. That asymmetry is the defect under test: one
  # unimplemented capability is loud, the other is not.
  class NonDiscoveringAdapter < Corvid::Adapters::Base
    def verify_tribal_enrollment(_patient_identifier) = { enrolled: true }
    def verify_identity_documents(_patient_identifier) = { ssn_present: true, dob_present: true }
    def verify_residency(_patient_identifier) = { on_reservation: true }
  end

  # -- the capability predicate ---------------------------------------------

  test "Base does not claim coverage discovery" do
    refute Corvid::Adapters::Base.new.supports_coverage_discovery?
  end

  test "an adapter that overrides get_coverages claims coverage discovery" do
    assert DiscoveringAdapter.new.supports_coverage_discovery?
  end

  test "an adapter that inherits get_coverages does not claim coverage discovery" do
    refute NonDiscoveringAdapter.new.supports_coverage_discovery?
  end

  test "MockAdapter claims coverage discovery because it overrides get_coverages" do
    assert Corvid::Adapters::MockAdapter.new.supports_coverage_discovery?
  end

  # This is the finding. FhirAdapter is the production adapter and cannot
  # see coverages at all.
  test "FhirAdapter does not claim coverage discovery" do
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: "https://fhir.example.test")
    refute adapter.supports_coverage_discovery?,
      "FhirAdapter must not claim a capability it inherits as [] from Base"
  end

  # The predicate is derived from the method owner rather than a hand-kept
  # flag, so a new adapter cannot forget to declare itself.
  test "the predicate tracks the method owner, not a hand-maintained list" do
    anonymous = Class.new(Corvid::Adapters::Base) do
      def get_coverages(_patient_identifier) = []
    end
    assert anonymous.new.supports_coverage_discovery?
  end

  # -- the staff-triggered path refuses rather than no-ops ------------------

  test "check_payer_eligibility! refuses when the adapter cannot discover coverage" do
    Corvid::TenantContext.with_tenant(TENANT) do
      referral = referral_with_checklist
      service = Corvid::EligibilityChecklistService.new(adapter: NonDiscoveringAdapter.new)

      error = assert_raises(Corvid::CoverageDiscoveryUnavailable) do
        service.check_payer_eligibility!(referral)
      end

      assert_match(/NonDiscoveringAdapter/, error.message,
        "the refusal must name the adapter so staff can act on it")
      refute referral.reload.eligibility_checklist.insurance_verified
    end
  end

  test "check_payer_eligibility! still verifies when the adapter can discover coverage" do
    Corvid::TenantContext.with_tenant(TENANT) do
      referral = referral_with_checklist
      service = Corvid::EligibilityChecklistService.new(adapter: DiscoveringAdapter.new)
      service.check_payer_eligibility!(referral)
      assert referral.reload.eligibility_checklist.insurance_verified
    end
  end

  # Regression pin for the behaviour that was already correct: a capable
  # adapter returning no coverage must NOT flip the item.
  test "a capable adapter finding no coverage does not verify insurance" do
    Corvid::TenantContext.with_tenant(TENANT) do
      referral = referral_with_checklist
      empty = Class.new(Corvid::Adapters::Base) do
        def get_coverages(_patient_identifier) = []
      end
      service = Corvid::EligibilityChecklistService.new(adapter: empty.new)
      service.check_payer_eligibility!(referral)
      refute referral.reload.eligibility_checklist.insurance_verified
    end
  end

  # -- auto-populate stays best-effort -------------------------------------

  test "populate! does not raise when the adapter cannot discover coverage" do
    Corvid::TenantContext.with_tenant(TENANT) do
      referral = bare_referral
      service = Corvid::EligibilityChecklistService.new(adapter: NonDiscoveringAdapter.new)

      checklist = nil
      assert_nothing_raised { checklist = service.populate!(referral) }
      refute checklist.insurance_verified,
        "an adapter that never asked a payer must not mark insurance verified"
    end
  end

  private

  FACILITY = "fac_example"

  # Must be called from within `Corvid::TenantContext.with_tenant` —
  # TenantScoped's default_scope raises if no tenant is set.
  def bare_referral
    Corvid::PrcReferral.create!(
      case: Corvid::Case.create!(patient_identifier: "pt_example", facility_identifier: FACILITY),
      referral_identifier: "rf_cov_#{SecureRandom.hex(4)}",
      facility_identifier: FACILITY
    )
  end

  def referral_with_checklist
    referral = bare_referral
    referral.create_eligibility_checklist!(
      tenant_identifier: TENANT, facility_identifier: FACILITY
    )
    referral
  end
end
