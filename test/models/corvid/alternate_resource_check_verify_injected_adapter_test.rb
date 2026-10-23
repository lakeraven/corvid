# frozen_string_literal: true

require "test_helper"

# Issue #675 / PR #693: verify!(adapter:) must record Medicaid eligibility
# groups from the injected adapter only (ADR 0005).
class Corvid::AlternateResourceCheckVerifyInjectedAdapterTest < ActiveSupport::TestCase
  TENANT = "tnt_g693_verify_adapter"
  PATIENT_ID = "pt_g693_verify_adapter"
  FACILITY = "fac_g693"

  setup do
    @global_adapter = Corvid.adapter
    @global_adapter.reset! if @global_adapter.respond_to?(:reset!)
  end

  test "verify! with injected adapter does not call global get_coverages and records group from injected coverages only" do
    with_tenant(TENANT) do
      register_patient_on!(@global_adapter)
      @global_adapter.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        eligibility_group: "expansion_adult",
        eligibility_group_source: "eligibility_response",
        coverage_start: Date.current.beginning_of_year,
        coverage_end: Date.current.end_of_year + 1.year
      )

      injected = Corvid::Adapters::MockAdapter.new
      register_patient_on!(injected)
      injected.add_coverage(
        PATIENT_ID,
        coverage_type: "medicaid",
        eligible: true,
        state: "XA",
        coverage_start: Date.current.beginning_of_year,
        coverage_end: Date.current.end_of_year + 1.year
      )
      stub_verify_eligibility_on!(injected, eligible: true, policy_token: "TEST-POLICY-G693")

      global_get_coverages_calls = []
      orig_get_coverages = @global_adapter.method(:get_coverages)
      @global_adapter.define_singleton_method(:get_coverages) do |patient_identifier|
        global_get_coverages_calls << patient_identifier
        orig_get_coverages.call(patient_identifier)
      end

      check = create_medicaid_check!

      assert check.verify!(adapter: injected)
      check.reload

      assert_empty global_get_coverages_calls,
        "verify!(adapter:) must not read coverages from the global adapter"
      refute_equal "expansion_adult", check.eligibility_group,
        "eligibility group must not come from global adapter coverages"
      refute_equal "eligibility_response", check.eligibility_group_source,
        "eligibility group source must not come from global adapter coverages"
      assert_equal "inferred", check.eligibility_group_source
      assert_not_nil check.eligibility_group
    end
  end

  private

  def register_patient_on!(adapter)
    adapter.add_patient(
      PATIENT_ID,
      display_name: "TEST,PATIENT G693",
      dob: Date.new(1996, 6, 15),
      sex: "F",
      ssn_last4: "0000"
    )
  end

  def create_medicaid_check!
    kase = Corvid::Case.create!(
      patient_identifier: PATIENT_ID,
      lifecycle_status: "intake",
      facility_identifier: FACILITY
    )
    referral = Corvid::PrcReferral.create!(
      case: kase,
      referral_identifier: "rf_g693_verify_#{SecureRandom.hex(4)}",
      facility_identifier: FACILITY
    )
    Corvid::AlternateResourceCheck.create!(
      prc_referral: referral,
      resource_type: "medicaid",
      status: "not_checked"
    )
  end

  def stub_verify_eligibility_on!(adapter, eligible:, policy_token: nil)
    adapter.define_singleton_method(:verify_eligibility) do |_patient_identifier, _resource_type|
      {
        eligible: eligible,
        policy_token: policy_token,
        coverage_start: Date.current.beginning_of_year,
        coverage_end: Date.current.end_of_year + 1.year,
        renewal_date: nil
      }
    end
  end
end
