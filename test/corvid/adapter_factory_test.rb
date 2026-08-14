# frozen_string_literal: true

require "minitest/autorun"
require "ostruct"
require "corvid/adapter_factory"

class Corvid::AdapterFactoryTest < Minitest::Test
  def setup
    Corvid::AdapterFactory.reset!
  end

  def teardown
    Corvid::AdapterFactory.reset!
  end

  FakeSecretReader = Struct.new(:secrets) do
    def fetch(secret_ref)
      secrets.fetch(secret_ref)
    end
  end

  def config_for(adapter_type, endpoint: nil, secret_ref: nil, extra: {})
    OpenStruct.new(adapter_type: adapter_type, endpoint: endpoint, secret_ref: secret_ref, config: extra)
  end

  # -- built-in: mock -----------------------------------------------------

  def test_builds_mock_adapter
    adapter = Corvid::AdapterFactory.build(config_for("mock"), secret_reader: FakeSecretReader.new({}))
    assert_instance_of Corvid::Adapters::MockAdapter, adapter
  end

  def test_mock_adapter_type_accepts_symbol_too
    adapter = Corvid::AdapterFactory.build(config_for(:mock), secret_reader: FakeSecretReader.new({}))
    assert_instance_of Corvid::Adapters::MockAdapter, adapter
  end

  # -- built-in: fhir -------------------------------------------------------

  def test_builds_fhir_adapter_with_endpoint
    adapter = Corvid::AdapterFactory.build(
      config_for("fhir", endpoint: "https://fhir.example.org"),
      secret_reader: FakeSecretReader.new({})
    )
    assert_instance_of Corvid::Adapters::FhirAdapter, adapter
    assert_equal "https://fhir.example.org", adapter.base_url
  end

  def test_fhir_adapter_resolves_bearer_token_via_secret_reader
    secret_reader = FakeSecretReader.new({ "fhir/tnt_yakama" => "sekret-token" })
    adapter = Corvid::AdapterFactory.build(
      config_for("fhir", endpoint: "https://fhir.example.org", secret_ref: "fhir/tnt_yakama"),
      secret_reader: secret_reader
    )
    assert_equal "sekret-token", adapter.instance_variable_get(:@bearer_token)
  end

  def test_fhir_adapter_passes_extra_config_kwargs
    adapter = Corvid::AdapterFactory.build(
      config_for("fhir", endpoint: "https://fhir.example.org", extra: { "open_timeout" => 5 }),
      secret_reader: FakeSecretReader.new({})
    )
    assert_instance_of Corvid::Adapters::FhirAdapter, adapter
  end

  # -- register / unknown types ---------------------------------------------

  def test_unknown_adapter_type_raises
    error = assert_raises(Corvid::AdapterFactory::UnknownAdapterTypeError) do
      Corvid::AdapterFactory.build(config_for("rpms_direct"), secret_reader: FakeSecretReader.new({}))
    end
    assert_match(/rpms_direct/, error.message)
  end

  def test_register_adds_a_builder_for_a_new_adapter_type
    fake_adapter = Object.new
    Corvid::AdapterFactory.register("rpms_direct") { |_config, _secret| fake_adapter }

    result = Corvid::AdapterFactory.build(config_for("rpms_direct"), secret_reader: FakeSecretReader.new({}))
    assert_same fake_adapter, result
  end

  def test_register_can_override_a_builtin_builder
    fake_adapter = Object.new
    Corvid::AdapterFactory.register("mock") { |_config, _secret| fake_adapter }

    result = Corvid::AdapterFactory.build(config_for("mock"), secret_reader: FakeSecretReader.new({}))
    assert_same fake_adapter, result
  end

  def test_reset_restores_builtin_only_registry
    Corvid::AdapterFactory.register("rpms_direct") { |_c, _s| Object.new }
    Corvid::AdapterFactory.reset!

    assert_raises(Corvid::AdapterFactory::UnknownAdapterTypeError) do
      Corvid::AdapterFactory.build(config_for("rpms_direct"), secret_reader: FakeSecretReader.new({}))
    end
  end

  def test_build_defaults_secret_reader_to_configuration_secret_reader
    Corvid.reset_configuration!
    default_reader = Corvid.configuration.secret_reader
    adapter = Corvid::AdapterFactory.build(config_for("mock"))
    assert_instance_of Corvid::Adapters::MockAdapter, adapter
    assert_instance_of Corvid::SecretReader::Env, default_reader
  ensure
    Corvid.reset_configuration!
  end
end
