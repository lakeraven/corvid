# frozen_string_literal: true

require "minitest/autorun"
require "ostruct"
require "active_support/all"
require "corvid/adapters/mock_adapter"
require_relative "../../support/adapter_contract_tests"
require_relative "mock_adapter_contract_test"

# Probes for the contract suite itself: each runs the MockAdapter contract
# seed against an adapter that is broken in one way (the suite must fail)
# or valid in an unusual way (the suite must pass).
class Corvid::Adapters::AdapterContractSuiteTest < Minitest::Test
  # store_text hands back a token but keeps nothing.
  class LostTextWriteAdapter < Corvid::Adapters::MockAdapter
    def store_text(case_token:, kind:, text:)
      "nt_#{ULID.generate}"
    end
  end

  # The claim is stored (so check_claim_status finds it) but the submit
  # result carries no usable status.
  class NilClaimStatusAdapter < Corvid::Adapters::MockAdapter
    def submit_claim(claim_data)
      super.merge(status: nil)
    end
  end

  class BlankClaimStatusAdapter < Corvid::Adapters::MockAdapter
    def submit_claim(claim_data)
      super.merge(status: " ")
    end
  end

  # base.rb: coverage_start, coverage_end and renewal_date are Date or nil.
  class StringCoverageDateAdapter < Corvid::Adapters::MockAdapter
    def verify_eligibility(patient_identifier, resource_type)
      super&.merge(coverage_start: "2026-01-01")
    end
  end

  class StringRenewalDateAdapter < Corvid::Adapters::MockAdapter
    def verify_eligibility(patient_identifier, resource_type)
      super&.merge(renewal_date: "2026-12-31")
    end
  end

  # Implements coverage-type eligibility but has no 270/271 exchange.
  class NoDetailedEligibilityAdapter < Corvid::Adapters::MockAdapter
    def check_eligibility_detailed(_patient_identifier, _payer_identifier)
      raise NotImplementedError, "#{self.class}#check_eligibility_detailed not implemented"
    end
  end

  # A source that cannot answer clinical reads returns nil (base.rb).
  class UnknownClinicalReadsAdapter < Corvid::Adapters::MockAdapter
    def get_conditions(_patient_identifier)
      nil
    end

    def get_medications(_patient_identifier)
      nil
    end
  end

  def test_suite_rejects_a_store_text_that_keeps_nothing
    assert_contract_fails(LostTextWriteAdapter, :store_text)
  end

  def test_suite_rejects_a_nil_submit_claim_status
    assert_contract_fails(NilClaimStatusAdapter, :submit_claim)
  end

  def test_suite_rejects_a_blank_submit_claim_status
    assert_contract_fails(BlankClaimStatusAdapter, :submit_claim)
  end

  def test_suite_rejects_a_string_coverage_date
    assert_contract_fails(StringCoverageDateAdapter, :verify_eligibility)
  end

  def test_suite_rejects_a_string_renewal_date
    assert_contract_fails(StringRenewalDateAdapter, :verify_eligibility)
  end

  def test_suite_accepts_verify_eligibility_without_detailed_eligibility
    probe = probe_for(NoDetailedEligibilityAdapter)
    probe.define_singleton_method(:contract_unsupported) do
      { check_eligibility_detailed: "no 270/271 exchange in this probe" }
    end

    run_contract(probe, :verify_eligibility)
    run_contract(probe, :check_eligibility_detailed)
  end

  def test_suite_accepts_nil_conditions_and_medications_as_unknown
    probe = probe_for(UnknownClinicalReadsAdapter)

    run_contract(probe, :get_conditions)
    run_contract(probe, :get_medications)
  end

  private

  def probe_for(adapter_class)
    probe = Corvid::Adapters::MockAdapterContractTest.new("probe")
    probe.instance_variable_set(:@adapter, adapter_class.new.tap(&:reset!))
    probe
  end

  def run_contract(probe, method_name)
    probe.send(:"test_contract_#{method_name}")
  end

  def assert_contract_fails(adapter_class, method_name)
    assert_raises(Minitest::Assertion) { run_contract(probe_for(adapter_class), method_name) }
  end
end
