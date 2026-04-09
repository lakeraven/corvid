# frozen_string_literal: true

require "minitest/autorun"
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
end
