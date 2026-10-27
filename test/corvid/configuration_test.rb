# frozen_string_literal: true

require "minitest/autorun"
require "active_support/core_ext/numeric/time"
require "active_support/core_ext/object/json"
require "yaml"
require "corvid/configuration"

class Corvid::ConfigurationTest < Minitest::Test
  def setup
    Corvid.reset_configuration!
  end

  def teardown
    Corvid.reset_configuration!
  end

  # -- Configuration object ---------------------------------------------------

  def test_configuration_returns_a_singleton
    assert_same Corvid.configuration, Corvid.configuration
  end

  def test_reset_configuration_replaces_singleton
    original = Corvid.configuration
    Corvid.reset_configuration!
    refute_same original, Corvid.configuration
  end

  def test_configure_yields_configuration
    yielded = nil
    Corvid.configure { |c| yielded = c }
    assert_same Corvid.configuration, yielded
  end

  # -- adapter ----------------------------------------------------------------

  def test_adapter_starts_nil
    assert_nil Corvid.adapter
  end

  def test_adapter_can_be_set
    fake_adapter = Object.new
    Corvid.configure { |c| c.adapter = fake_adapter }
    assert_same fake_adapter, Corvid.adapter
  end

  # -- edi_adapter -----------------------------------------------------------

  def test_edi_adapter_starts_nil
    assert_nil Corvid.edi_adapter
  end

  def test_edi_adapter_can_be_set
    fake_edi = Object.new
    Corvid.configure { |c| c.edi_adapter = fake_edi }
    assert_same fake_edi, Corvid.edi_adapter
  end

  def test_edi_adapter_resets_with_configuration
    Corvid.configure { |c| c.edi_adapter = Object.new }
    Corvid.reset_configuration!
    assert_nil Corvid.edi_adapter
  end

  # -- phi_sanitizer fail-safe default ---------------------------------------

  def test_phi_sanitizer_default_is_fail_safe_redact_all
    # Per ADR 0003: forgetting to configure must NOT increase PHI exposure.
    # Default replaces all input with [REDACTED] until host wires a real one.
    assert_equal "[REDACTED]", Corvid.sanitize_phi("Patient Doe, Jane")
    assert_equal "[REDACTED]", Corvid.sanitize_phi("SSN: 123-45-6789")
    assert_equal "[REDACTED]", Corvid.sanitize_phi(nil)
  end

  def test_phi_sanitizer_can_be_replaced
    Corvid.configure do |c|
      c.phi_sanitizer = ->(msg) { msg.to_s.gsub(/\d/, "X") }
    end
    assert_equal "SSN: XXX-XX-XXXX", Corvid.sanitize_phi("SSN: 123-45-6789")
  end

  # -- on_provenance hook -----------------------------------------------------

  def test_on_provenance_starts_nil
    assert_nil Corvid.configuration.on_provenance
  end

  def test_on_provenance_can_be_set
    captured = nil
    Corvid.configure do |c|
      c.on_provenance = ->(**attrs) { captured = attrs }
    end
    Corvid.configuration.on_provenance.call(target_type: "Corvid::Case", target_id: "1")
    assert_equal({ target_type: "Corvid::Case", target_id: "1" }, captured)
  end

  def test_on_provenance_safe_to_call_when_unset
    # Hosts that don't need provenance can leave the hook nil.
    # Engine code uses safe-nav: Corvid.configuration.on_provenance&.call(...)
    assert_nil Corvid.configuration.on_provenance
  end

  # -- fetch_provenance hook --------------------------------------------------

  def test_fetch_provenance_default_returns_empty_array
    result = Corvid.configuration.fetch_provenance.call(
      target_type: "Corvid::Case", target_id: "1"
    )
    assert_equal [], result
  end

  def test_fetch_provenance_can_be_replaced
    Corvid.configure do |c|
      c.fetch_provenance = ->(**) { [ { activity: "CREATE" } ] }
    end
    result = Corvid.configuration.fetch_provenance.call(target_type: "x", target_id: "y")
    assert_equal [ { activity: "CREATE" } ], result
  end

  # -- alternate_resource_check_max_age (#640) ------------------------------

  def test_alternate_resource_check_max_age_defaults
    max_age = Corvid.configuration.alternate_resource_check_max_age

    assert max_age.frozen?
    assert_equal 30.days, max_age.fetch("medicaid")
    %w[medicare_a medicare_b medicare_d].each do |type|
      assert_equal 90.days, max_age.fetch(type)
    end

    other_types = Corvid::Configuration::ALTERNATE_RESOURCE_TYPES - %w[medicaid medicare_a medicare_b medicare_d]
    other_types.each do |type|
      assert_equal 90.days, max_age.fetch(type), "expected 90.days default for #{type}"
    end
  end

  def test_alternate_resource_check_max_age_can_be_overridden_per_type
    Corvid.configure do |c|
      c.alternate_resource_check_max_age = { "medicaid" => 14.days }
    end

    max_age = Corvid.configuration.alternate_resource_check_max_age
    assert_equal 14.days, max_age.fetch("medicaid")
    assert_equal 90.days, max_age.fetch("medicare_a")
    assert_equal 90.days, max_age.fetch("private_insurance")
  end

  def test_alternate_resource_check_max_age_rejects_non_duration_values
    error = assert_raises(ArgumentError) do
      Corvid.configure { |c| c.alternate_resource_check_max_age = { "medicaid" => 30 } }
    end
    assert_match(/duration/i, error.message)
  end

  def test_alternate_resource_check_max_age_rejects_non_positive_duration
    error = assert_raises(ArgumentError) do
      Corvid.configure { |c| c.alternate_resource_check_max_age = { "medicaid" => 0.days } }
    end
    assert_match(/positive/i, error.message)
  end

  def test_alternate_resource_check_max_age_normalizes_symbol_keys_to_strings
    Corvid.configure { |c| c.alternate_resource_check_max_age = { medicaid: 7.days } }

    max_age = Corvid.configuration.alternate_resource_check_max_age
    assert_equal 7.days, max_age.fetch("medicaid")
  end

  def test_alternate_resource_check_max_age_rejects_unknown_resource_type_keys
    assert_raises(ArgumentError) do
      Corvid.configure { |c| c.alternate_resource_check_max_age = { "medicaidd" => 7.days } }
    end

    assert_raises(ArgumentError) do
      Corvid.configure { |c| c.alternate_resource_check_max_age = { unknown: 7.days } }
    end
  end

  # -- issue #712 defaults ----------------------------------------------------

  def test_fresh_configuration_issue_712_defaults
    config = Corvid::Configuration.new

    assert_equal %w[medicaid], config.month_bounded_eligibility_resource_types
    assert_equal [ Date.new(9999, 12, 31) ], config.placeholder_coverage_end_dates
    assert_equal 25, config.placeholder_coverage_end_horizon_years
  end

  # -- verification snapshot keys (ADR 0008) ---------------------------------

  def test_verification_snapshot_keys_defaults_to_empty_hash
    assert_equal({}, Corvid.configuration.verification_snapshot_keys)
  end

  def test_verification_snapshot_key_version_defaults_to_nil
    assert_nil Corvid.configuration.verification_snapshot_key_version
  end

  def test_configuration_inspect_does_not_reveal_snapshot_key_material
    key = "test-snapshot-key-0001-xxxxxxxxxxxxxxxx"
    Corvid.configure do |c|
      c.verification_snapshot_keys = { "v1-test" => key }
      c.verification_snapshot_key_version = "v1-test"
    end

    inspected = Corvid.configuration.inspect
    refute_includes inspected, key
    refute_includes inspected, "test-snapshot-key-0001"
  end

  def test_configuration_as_json_to_json_and_to_yaml_never_reveal_snapshot_key_material
    key = "test-snapshot-key-0001-xxxxxxxxxxxxxxxx"
    Corvid.configure do |c|
      c.verification_snapshot_keys = { "v1-test" => key }
      c.verification_snapshot_key_version = "v1-test"
    end

    config = Corvid.configuration
    serialized_forms = [
      config.as_json,
      JSON.parse(config.to_json),
      config.to_yaml
    ]

    serialized_forms.each do |serialized|
      refute_includes serialized.to_s, key
      refute_includes serialized.to_s, "test-snapshot-key-0001"
    end
  end
end
