# frozen_string_literal: true

require "minitest/autorun"
require "corvid/adapters/fhir_adapter"

# The FhirAdapter authenticates with a static bearer_token OR a dynamic
# token_source (any callable returning a token string) so it can carry a
# freshly-refreshed SMART Backend Services token on every request rather
# than a token frozen at construction.
class Corvid::Adapters::FhirAdapterTokenSourceTest < Minitest::Test
  BASE = "https://fhir.example.com/r4"

  def test_static_bearer_token_still_resolves
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, bearer_token: "static-123")
    assert_equal "static-123", adapter.send(:resolve_bearer_token)
  end

  def test_token_source_is_called_per_request
    tokens = [ "t1", "t2", "t3" ]
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, token_source: -> { tokens.shift })
    assert_equal "t1", adapter.send(:resolve_bearer_token)
    assert_equal "t2", adapter.send(:resolve_bearer_token)
    assert_equal "t3", adapter.send(:resolve_bearer_token)
  end

  def test_token_source_takes_precedence_over_static_token
    adapter = Corvid::Adapters::FhirAdapter.new(
      base_url: BASE, bearer_token: "static", token_source: -> { "dynamic" }
    )
    assert_equal "dynamic", adapter.send(:resolve_bearer_token)
  end

  def test_no_auth_configured_resolves_nil
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE)
    assert_nil adapter.send(:resolve_bearer_token)
  end

  def test_non_callable_token_source_is_rejected
    assert_raises(ArgumentError) do
      Corvid::Adapters::FhirAdapter.new(base_url: BASE, token_source: "not-callable")
    end
  end

  def test_token_source_returning_nil_hard_fails
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, token_source: -> { })
    assert_raises(Corvid::Adapters::FhirAdapter::TokenSourceError) do
      adapter.send(:resolve_bearer_token)
    end
  end

  def test_token_source_returning_blank_string_hard_fails
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, token_source: -> { "" })
    assert_raises(Corvid::Adapters::FhirAdapter::TokenSourceError) do
      adapter.send(:resolve_bearer_token)
    end
  end

  # --- blank tokens ------------------------------------------------------------

  # Whitespace passes a bare empty? check, gets cached upstream, and goes out
  # as a malformed "Bearer  " header: a permanent 401 that presents as
  # missing data rather than as broken auth.
  def test_token_source_returning_whitespace_only_hard_fails
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, token_source: -> { "  \t\n" })
    assert_raises(Corvid::Adapters::FhirAdapter::TokenSourceError) do
      adapter.send(:resolve_bearer_token)
    end
  end

  def test_blank_static_bearer_token_is_rejected_at_construction
    assert_raises(ArgumentError) do
      Corvid::Adapters::FhirAdapter.new(base_url: BASE, bearer_token: "   ")
    end
  end

  # TokenSourceError messages land in Rails logs; a token that failed *our*
  # validation may still be live credential material.
  def test_token_source_error_never_renders_the_token_value
    leaky = Class.new do
      def inspect = "#<Token value=\"SUPER-SECRET-BEARER\">"
      def to_s = "SUPER-SECRET-BEARER"
    end.new
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, token_source: -> { leaky })

    err = assert_raises(Corvid::Adapters::FhirAdapter::TokenSourceError) do
      adapter.send(:resolve_bearer_token)
    end
    refute_match(/SUPER-SECRET-BEARER/, err.message)
  end

  # --- transport security ------------------------------------------------------

  def test_http_base_url_with_token_source_is_rejected_at_construction
    err = assert_raises(Corvid::Adapters::FhirAdapter::InsecureTransportError) do
      Corvid::Adapters::FhirAdapter.new(
        base_url: "http://fhir.example.com/r4", token_source: -> { "t" }
      )
    end
    assert_match(/https/, err.message)
  end

  def test_http_base_url_with_static_bearer_token_is_rejected_at_construction
    assert_raises(Corvid::Adapters::FhirAdapter::InsecureTransportError) do
      Corvid::Adapters::FhirAdapter.new(base_url: "http://fhir.example.com/r4", bearer_token: "t")
    end
  end

  def test_insecure_transport_error_is_an_argument_error
    assert_operator Corvid::Adapters::FhirAdapter::InsecureTransportError, :<, ArgumentError
  end

  def test_unauthenticated_http_base_url_is_still_allowed
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: "http://fhir.example.com/r4")
    assert_equal "http://fhir.example.com/r4", adapter.base_url
  end

  def test_explicit_opt_out_permits_http_for_localhost_testing
    adapter = Corvid::Adapters::FhirAdapter.new(
      base_url: "http://localhost:8080/r4", token_source: -> { "t" }, allow_insecure_http: true
    )
    assert_equal "http://localhost:8080/r4", adapter.base_url
  end

  # Defense in depth: base_url is not the only URL that can reach the wire.
  def test_request_to_an_http_url_refuses_to_send_the_token
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, token_source: -> { "tok" })
    adapter.define_singleton_method(:build_http) { |_uri| flunk "must not reach the network" }

    assert_raises(Corvid::Adapters::FhirAdapter::InsecureTransportError) do
      adapter.send(:execute_http, :get, "http://fhir.example.com/r4/Patient/1")
    end
  end

  # --- caller-supplied Authorization header ------------------------------------
  #
  # The guard keys off what the request actually carries, not off what was
  # configured: a header passed straight in is just as much a credential.

  def test_preset_authorization_header_over_http_is_rejected_at_construction
    assert_raises(Corvid::Adapters::FhirAdapter::InsecureTransportError) do
      Corvid::Adapters::FhirAdapter.new(
        base_url: "http://fhir.example.com/r4",
        headers: { "Authorization" => "Bearer LEAK" }
      )
    end
  end

  # HTTP header names are case-insensitive; so is the guard.
  def test_lowercase_preset_authorization_header_over_http_is_rejected
    assert_raises(Corvid::Adapters::FhirAdapter::InsecureTransportError) do
      Corvid::Adapters::FhirAdapter.new(
        base_url: "http://fhir.example.com/r4",
        headers: { "authorization" => "Bearer LEAK" }
      )
    end
  end

  def test_preset_authorization_header_is_blocked_per_request_too
    adapter = Corvid::Adapters::FhirAdapter.new(
      base_url: BASE, headers: { "Authorization" => "Bearer LEAK" }
    )
    adapter.define_singleton_method(:build_http) { |_uri| flunk "must not reach the network" }

    assert_raises(Corvid::Adapters::FhirAdapter::InsecureTransportError) do
      adapter.send(:execute_http, :get, "http://fhir.example.com/r4/Patient/1")
    end
  end

  def test_preset_authorization_header_over_https_is_allowed
    adapter = Corvid::Adapters::FhirAdapter.new(
      base_url: BASE, headers: { "Authorization" => "Bearer ok" }
    )
    assert_equal "Bearer ok", capture_request(adapter, "#{BASE}/Patient/1")["Authorization"]
  end

  # The exemption that must survive: no credential, no TLS requirement.
  def test_unauthenticated_http_request_still_goes_out
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: "http://internal.example.com/r4")
    req = capture_request(adapter, "http://internal.example.com/r4/Patient/1")
    assert_nil req["Authorization"]
  end

  # --- opt-out is strict and loopback-scoped -----------------------------------

  # The trap: `allow_insecure_http: ENV["ALLOW_INSECURE_HTTP"]` with the var
  # set to "false" is TRUTHY in Ruby, silently inverting the setting.
  def test_string_false_opt_out_is_a_configuration_error
    err = assert_raises(ArgumentError) do
      Corvid::Adapters::FhirAdapter.new(base_url: BASE, allow_insecure_http: "false")
    end
    assert_match(/literal boolean/, err.message)
  end

  def test_string_true_opt_out_is_also_a_configuration_error
    assert_raises(ArgumentError) do
      Corvid::Adapters::FhirAdapter.new(base_url: BASE, allow_insecure_http: "true")
    end
  end

  def test_explicit_false_opt_out_is_accepted
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, allow_insecure_http: false)
    assert_equal BASE, adapter.base_url
  end

  def test_opt_out_does_not_cover_a_remote_host
    err = assert_raises(Corvid::Adapters::FhirAdapter::InsecureTransportError) do
      Corvid::Adapters::FhirAdapter.new(
        base_url: "http://fhir.example.com/r4", token_source: -> { "t" },
        allow_insecure_http: true
      )
    end
    assert_match(/loopback/, err.message)
  end

  def test_opt_out_covers_loopback_forms
    [ "http://localhost:8080/r4", "http://127.0.0.1:8080/r4",
      "http://127.1.2.3:8080/r4", "http://[::1]:8080/r4",
      "http://fhir.localhost:8080/r4" ].each do |url|
      adapter = Corvid::Adapters::FhirAdapter.new(
        base_url: url, token_source: -> { "t" }, allow_insecure_http: true
      )
      assert_equal "Bearer t", capture_request(adapter, "#{adapter.base_url}/Patient/1")["Authorization"],
                   "#{url} should be treated as loopback"
    end
  end

  # --- immutability ------------------------------------------------------------

  # Validating at construction is worthless if the checked value can be
  # mutated afterwards through the reader.
  def test_base_url_is_frozen_against_post_construction_mutation
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, bearer_token: "t")
    assert_predicate adapter.base_url, :frozen?
    assert_raises(FrozenError) { adapter.base_url.replace("http://evil.example.com/r4") }
  end

  # An exception message must not carry a FHIR path (record identifiers).
  def test_insecure_transport_error_omits_the_request_path
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, token_source: -> { "tok" })
    err = assert_raises(Corvid::Adapters::FhirAdapter::InsecureTransportError) do
      adapter.send(:execute_http, :get, "http://fhir.example.com/r4/Patient/PT-9911")
    end
    refute_match(/PT-9911/, err.message)
  end

  def test_request_carries_resolved_token_as_bearer_header
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, token_source: -> { "resolved-xyz" })
    assert_equal "Bearer resolved-xyz", capture_request(adapter, "#{BASE}/Patient/1")["Authorization"]
  end

  private

  # Intercept at the network boundary so no real call is made; return the
  # request that would have gone out.
  def capture_request(adapter, url)
    captured = nil
    fake_http = Object.new
    fake_http.define_singleton_method(:request) do |req|
      captured = req
      Net::HTTPOK.new("1.1", "200", "OK")
    end
    adapter.define_singleton_method(:build_http) { |_uri| fake_http }

    adapter.send(:execute_http, :get, url)
    captured
  end
end
