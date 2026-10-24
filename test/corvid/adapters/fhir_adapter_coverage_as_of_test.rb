# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "active_support/all"
require "corvid/adapters/fhir_adapter"

class Corvid::Adapters::FhirAdapterCoverageAsOfTest < Minitest::Test
  def setup
    @adapter = Corvid::Adapters::FhirAdapter.new(base_url: "https://fhir.example.com/r4")
  end

  def test_verify_eligibility_as_of_from_coverage_meta_last_updated
    bundle = medicaid_coverage_bundle(
      meta: { "lastUpdated" => "2026-10-05T08:30:00Z" }
    )
    @adapter.stub(:fhir_search, bundle) do
      result = @adapter.verify_eligibility("pt_asof_695", "medicaid")
      assert_equal Time.utc(2026, 10, 5, 8, 30), result[:as_of]
    end
  end

  def test_verify_eligibility_as_of_nil_when_meta_missing
    bundle = medicaid_coverage_bundle
    @adapter.stub(:fhir_search, bundle) do
      result = @adapter.verify_eligibility("pt_asof_696", "medicaid")
      assert_nil result[:as_of]
      refute result.key?(:as_of) && result[:as_of].is_a?(Time)
    end
  end

  def test_verify_eligibility_as_of_nil_when_meta_last_updated_unparseable
    bundle = medicaid_coverage_bundle(meta: { "lastUpdated" => "not-an-instant" })
    @adapter.stub(:fhir_search, bundle) do
      result = @adapter.verify_eligibility("pt_asof_697", "medicaid")
      assert_nil result[:as_of]
    end
  end

  private

  def medicaid_coverage_bundle(meta: nil)
    resource = {
      "resourceType" => "Coverage",
      "id" => "cov_asof_695",
      "status" => "active",
      "type" => { "coding" => [ { "code" => "MCDSC" } ] },
      "payor" => [ { "display" => "TEST MEDICAID PAYER" } ]
    }
    resource["meta"] = meta if meta

    {
      "resourceType" => "Bundle",
      "entry" => [ { "resource" => resource } ]
    }
  end
end
