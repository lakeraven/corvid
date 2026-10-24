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

  def test_verify_eligibility_non_hash_meta_yields_nil_as_of_and_eligible_from_status
    [ "bogus", [] ].each_with_index do |meta, index|
      bundle = medicaid_coverage_bundle(meta: meta)
      @adapter.stub(:fhir_search, bundle) do
        result = @adapter.verify_eligibility("pt_asof_non_hash_meta_#{index}", "medicaid")
        assert_equal true, result[:eligible]
        assert_nil result[:as_of]
      end
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

  INVALID_FHIR_INSTANTS = [
    "0000-01-01T00:00:00Z",
    "2026-10-05T08:30:00",
    "2026-10-05T08:30:00+14:01",
    "2026-10-05T08:30:00+23:59",
    "2026-02-30T00:00:00Z",
    "2026-10-05T08:30:60Z",
    "2026-10-05T24:00:00Z",
    "2026-10-05",
    "2026-10-05T08:30Z"
  ].freeze

  def test_verify_eligibility_as_of_nil_for_non_fhir_instants
    INVALID_FHIR_INSTANTS.each_with_index do |last_updated, index|
      bundle = medicaid_coverage_bundle(meta: { "lastUpdated" => last_updated })
      @adapter.stub(:fhir_search, bundle) do
        result = @adapter.verify_eligibility("pt_asof_invalid_#{index}", "medicaid")
        assert_nil result[:as_of], "expected nil as_of for lastUpdated #{last_updated.inspect}"
      end
    end
  end

  def test_verify_eligibility_as_of_from_strict_fhir_instants
    expected = {
      "2026-10-05T08:30:00Z" => Time.utc(2026, 10, 5, 8, 30, 0),
      "2026-10-05T08:30:00.123456Z" => Time.utc(2026, 10, 5, 8, 30, Rational(123_456, 1_000_000)),
      "2026-10-05T02:30:00-06:00" => Time.utc(2026, 10, 5, 8, 30, 0),
      "2026-10-05T08:30:00+14:00" => Time.utc(2026, 10, 4, 18, 30, 0),
      "2026-10-05T08:30:00-12:00" => Time.utc(2026, 10, 5, 20, 30, 0)
    }

    expected.each_with_index do |(last_updated, want), index|
      bundle = medicaid_coverage_bundle(meta: { "lastUpdated" => last_updated })
      @adapter.stub(:fhir_search, bundle) do
        result = @adapter.verify_eligibility("pt_asof_valid_#{index}", "medicaid")
        assert_equal want, result[:as_of], "expected as_of for lastUpdated #{last_updated.inspect}"
      end
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
