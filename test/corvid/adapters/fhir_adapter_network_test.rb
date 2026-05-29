# frozen_string_literal: true

require "minitest/autorun"
require "corvid/adapters/fhir_adapter"

# Tests for the on-premises-friendly network keywords on FhirAdapter.
# Mode 2 (SaaS reaches into customer VPN/private CA) needs configurable
# timeouts, HTTP proxy support, and a CA-bundle pointer to talk to
# customer-internal FHIR endpoints.
class Corvid::Adapters::FhirAdapterNetworkTest < Minitest::Test
  BASE = "https://fhir.example.com/r4"
  TARGET = URI.parse("#{BASE}/Patient/1")

  # --- defaults preserved -----------------------------------------------------

  def test_defaults_preserve_current_timeout_behavior
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE)
    http = adapter.send(:build_http, TARGET)

    assert_equal 10, http.open_timeout
    assert_equal 30, http.read_timeout
  end

  def test_defaults_do_not_configure_proxy_or_ca
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE)
    http = adapter.send(:build_http, TARGET)

    refute http.proxy?
    assert_nil http.ca_file
    assert_nil http.ca_path
  end

  # --- timeout keywords -------------------------------------------------------

  def test_open_timeout_keyword_overrides_default
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, open_timeout: 45)
    http = adapter.send(:build_http, TARGET)

    assert_equal 45, http.open_timeout
    assert_equal 30, http.read_timeout
  end

  def test_read_timeout_keyword_overrides_default
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, read_timeout: 90)
    http = adapter.send(:build_http, TARGET)

    assert_equal 10, http.open_timeout
    assert_equal 90, http.read_timeout
  end

  # --- proxy --------------------------------------------------------------

  def test_proxy_uri_keyword_routes_through_a_proxy
    adapter = Corvid::Adapters::FhirAdapter.new(
      base_url: BASE,
      proxy_uri: "http://proxy.example.com:3128"
    )
    http = adapter.send(:build_http, TARGET)

    assert http.proxy?, "expected http to be configured for proxy"
    assert_equal "proxy.example.com", http.proxy_address
    assert_equal 3128, http.proxy_port
  end

  def test_proxy_uri_with_credentials_carries_them_through
    adapter = Corvid::Adapters::FhirAdapter.new(
      base_url: BASE,
      proxy_uri: "http://proxyuser:proxypass@proxy.example.com:3128"
    )
    http = adapter.send(:build_http, TARGET)

    assert http.proxy?
    assert_equal "proxyuser", http.proxy_user
    assert_equal "proxypass", http.proxy_pass
  end

  # --- private CA bundle ------------------------------------------------------

  def test_ca_file_keyword_pins_a_private_ca_bundle
    adapter = Corvid::Adapters::FhirAdapter.new(
      base_url: BASE,
      ca_file: "/etc/ssl/customer-root.pem"
    )
    http = adapter.send(:build_http, TARGET)

    assert_equal "/etc/ssl/customer-root.pem", http.ca_file
  end

  def test_ca_path_keyword_pins_a_private_ca_directory
    adapter = Corvid::Adapters::FhirAdapter.new(
      base_url: BASE,
      ca_path: "/etc/ssl/customer-certs.d"
    )
    http = adapter.send(:build_http, TARGET)

    assert_equal "/etc/ssl/customer-certs.d", http.ca_path
  end

  # --- TLS still enabled for https URIs --------------------------------------

  def test_https_uri_still_enables_ssl_with_custom_ca
    adapter = Corvid::Adapters::FhirAdapter.new(
      base_url: BASE,
      ca_file: "/etc/ssl/customer-root.pem"
    )
    http = adapter.send(:build_http, TARGET)

    assert http.use_ssl?
  end

  def test_http_uri_does_not_enable_ssl
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: "http://internal.example.com/r4")
    http = adapter.send(:build_http, URI.parse("http://internal.example.com/r4/Patient/1"))

    refute http.use_ssl?
  end
end
