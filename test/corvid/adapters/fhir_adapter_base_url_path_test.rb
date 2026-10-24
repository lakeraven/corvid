# frozen_string_literal: true

require "minitest/autorun"
require "uri"
require "openssl"
require "corvid"
require "corvid/adapters/fhir_adapter"
require "corvid/adapters/fhir_demo_adapter"
require "corvid/auth/backend_services_client"

# Issue #679: FHIR base_url must be path-qualified so bearer tokens and
# search next links stay scoped to the configured FHIR base, not the whole host.
class Corvid::Adapters::FhirAdapterBaseUrlPathTest < Minitest::Test
  EXAMPLE_QUALIFIED = "https://fhir.vendor.example/r4"

  BARE_BASE_URLS = [
    "https://fhir.vendor.example",
    "https://fhir.vendor.example/",
    "https://fhir.vendor.example:8443/"
  ].freeze

  QUALIFIED_BASE_URLS = [
    "https://fhir.vendor.example/r4",
    "https://fhir.vendor.example/r4/",
    "https://fhir.vendor.example/fhir/R4"
  ].freeze

  def test_rejects_bare_https_base_url_without_credentials
    assert_rejects_unqualified_base("https://fhir.vendor.example")
  end

  def test_rejects_bare_https_base_url_with_trailing_slash_without_credentials
    assert_rejects_unqualified_base("https://fhir.vendor.example/")
  end

  def test_rejects_bare_https_base_url_with_explicit_port_without_credentials
    assert_rejects_unqualified_base("https://fhir.vendor.example:8443/")
  end

  def test_rejects_bare_loopback_http_base_url_with_allow_insecure_http_without_credentials
    assert_rejects_unqualified_base(
      "http://localhost:8080",
      allow_insecure_http: true
    )
  end

  def test_rejects_bare_https_base_url_with_static_bearer_token
    BARE_BASE_URLS.each do |url|
      assert_rejects_unqualified_base(url, bearer_token: "synthetic-token")
    end
  end

  def test_rejects_bare_https_base_url_with_token_source
    BARE_BASE_URLS.each do |url|
      assert_rejects_unqualified_base(url, token_source: -> { "synthetic-token" })
    end
  end

  def test_rejects_bare_loopback_http_base_url_with_credentials_and_allow_insecure_http
    assert_rejects_unqualified_base(
      "http://localhost:8080",
      token_source: -> { "synthetic-token" },
      allow_insecure_http: true
    )
  end

  def test_accepts_path_qualified_https_base_url
    QUALIFIED_BASE_URLS.each do |url|
      adapter = Corvid::Adapters::FhirAdapter.new(base_url: url)
      refute_empty URI.parse(adapter.base_url).path.delete("/"),
                   "accepted base_url must retain a non-empty path"
    end
  end

  def test_accepts_path_qualified_base_url_with_bearer_token
    adapter = Corvid::Adapters::FhirAdapter.new(
      base_url: "https://fhir.vendor.example/r4",
      bearer_token: "synthetic-token"
    )
    assert_equal "https://fhir.vendor.example/r4", adapter.base_url
  end

  def test_malformed_base_url_without_host_still_rejected_when_credentialed
    err = assert_raises(Corvid::Adapters::FhirAdapter::InsecureTransportError) do
      Corvid::Adapters::FhirAdapter.new(base_url: "not-a-url", bearer_token: "t")
    end
    assert_match(/invalid FHIR base URL|refuses to send an Authorization/i, err.message)
  end

  def test_fhir_demo_adapter_constructs_with_empty_resources
    adapter = Corvid::Adapters::FhirDemoAdapter.new(resources: [])
    assert_instance_of Corvid::Adapters::FhirDemoAdapter, adapter
  end

  def test_fhir_demo_adapter_base_url_is_path_qualified
    adapter = Corvid::Adapters::FhirDemoAdapter.new(resources: [])
    path = URI.parse(adapter.base_url).path
    refute_empty path.delete("/"),
                 "FhirDemoAdapter base_url must include a non-empty FHIR path (e.g. memory://fhir-demo/r4)"
  end

  def test_configure_rejects_fhir_adapter_with_bare_base_url
    Corvid.reset_configuration!
    err = assert_raises(ArgumentError) do
      Corvid.configure do |c|
        c.adapter = Corvid::Adapters::FhirAdapter.new(base_url: "https://fhir.vendor.example")
      end
    end
    assert_unqualified_base_url_message(err.message)
  ensure
    Corvid.reset_configuration!
  end

  def test_backend_services_client_token_source_wiring_rejects_bare_fhir_base_url
    client = backend_services_client
    err = assert_raises(ArgumentError) do
      Corvid::Adapters::FhirAdapter.new(
        base_url: "https://fhir.vendor.example",
        token_source: client
      )
    end
    assert_unqualified_base_url_message(err.message)
  end

  private

  def assert_rejects_unqualified_base(base_url, **options)
    err = assert_raises(ArgumentError) do
      Corvid::Adapters::FhirAdapter.new(base_url: base_url, **options)
    end
    assert_unqualified_base_url_message(err.message)
  end

  def assert_unqualified_base_url_message(message)
    assert_match(/base_url/i, message)
    assert_match(/path/i, message)
    assert_includes message, EXAMPLE_QUALIFIED
  end

  def backend_services_client
    Corvid::Auth::BackendServicesClient.new(
      token_endpoint: "https://fhir.vendor.example/oauth2/token",
      client_id: "corvid-test-client",
      private_key: OpenSSL::PKey::RSA.new(2048),
      kid: "key-1",
      scopes: "system/Patient.read"
    )
  end
end
