# frozen_string_literal: true

require "minitest/autorun"
require "corvid/adapters/fhir_adapter"

# Issue #683: pagination and clinical bundle reads need distinct entry helpers.
class Corvid::Adapters::FhirAdapterBundleEntriesTest < Minitest::Test
  def setup
    @adapter = Corvid::Adapters::FhirAdapter.new(base_url: "https://fhir.vendor.example/r4")
  end

  def test_page_entries_returns_array_when_entry_is_array
    entries = [ { "resource" => { "resourceType" => "Patient" } } ]
    assert_equal entries, @adapter.send(:page_entries, { "entry" => entries })
  end

  def test_page_entries_returns_empty_array_when_entry_is_nil
    assert_equal [], @adapter.send(:page_entries, { "entry" => nil })
  end

  def test_page_entries_returns_empty_array_when_entry_key_missing
    assert_equal [], @adapter.send(:page_entries, {})
  end

  def test_page_entries_returns_empty_array_when_entry_is_not_array
    assert_equal [], @adapter.send(:page_entries, { "entry" => { "resource" => {} } })
    assert_equal [], @adapter.send(:page_entries, { "entry" => "not-an-array" })
  end

  def test_clinical_bundle_entries_returns_empty_array_when_entry_is_nil
    assert_equal [], @adapter.send(:clinical_bundle_entries, { "entry" => nil })
  end

  def test_clinical_bundle_entries_returns_empty_array_when_entry_key_missing
    assert_equal [], @adapter.send(:clinical_bundle_entries, {})
  end

  def test_clinical_bundle_entries_returns_nil_when_entry_is_not_array
    assert_nil @adapter.send(:clinical_bundle_entries, { "entry" => { "resource" => {} } })
    assert_nil @adapter.send(:clinical_bundle_entries, { "entry" => "not-an-array" })
  end

  def test_clinical_bundle_entries_returns_array_when_entry_is_array
    entries = [ { "resource" => { "resourceType" => "Condition" } } ]
    assert_equal entries, @adapter.send(:clinical_bundle_entries, { "entry" => entries })
  end
end
