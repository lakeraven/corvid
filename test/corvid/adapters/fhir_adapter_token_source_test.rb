# frozen_string_literal: true

require "minitest/autorun"
require "pp"
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

  # "Is this loopback?" is about the real network peers. A remote proxy in
  # front of a localhost URL still puts the token on the wire.
  def test_opt_out_does_not_cover_a_loopback_url_behind_a_remote_proxy
    err = assert_raises(Corvid::Adapters::FhirAdapter::InsecureTransportError) do
      Corvid::Adapters::FhirAdapter.new(
        base_url: "http://localhost:8080/r4", token_source: -> { "t" },
        allow_insecure_http: true, proxy_uri: "http://proxy.example.com:3128"
      )
    end
    assert_match(/proxy/, err.message)
  end

  def test_opt_out_still_covers_a_loopback_url_behind_a_loopback_proxy
    adapter = Corvid::Adapters::FhirAdapter.new(
      base_url: "http://localhost:8080/r4", token_source: -> { "t" },
      allow_insecure_http: true, proxy_uri: "http://127.0.0.1:3128"
    )
    assert_equal "Bearer t",
                 capture_request(adapter, "#{adapter.base_url}/Patient/1")["Authorization"]
  end

  # A name that is not in the RFC 6761 localhost family is an ordinary DNS
  # lookup, which a search domain or hostile resolver can point off-box.
  def test_dns_resolvable_loopback_aliases_are_not_treated_as_loopback
    [ "ip6-localhost", "localhost.evil.example.com", "notlocalhost" ].each do |host|
      assert_raises(Corvid::Adapters::FhirAdapter::InsecureTransportError,
                    "#{host} must not be trusted as loopback") do
        Corvid::Adapters::FhirAdapter.new(
          base_url: "http://#{host}:8080/r4", token_source: -> { "t" },
          allow_insecure_http: true
        )
      end
    end
  end

  def test_non_loopback_literal_addresses_are_rejected
    [ "10.0.0.1", "0.0.0.0", "[2001:db8::1]" ].each do |host|
      assert_raises(Corvid::Adapters::FhirAdapter::InsecureTransportError,
                    "#{host} must not be trusted as loopback") do
        Corvid::Adapters::FhirAdapter.new(
          base_url: "http://#{host}:8080/r4", token_source: -> { "t" },
          allow_insecure_http: true
        )
      end
    end
  end

  def test_opt_out_covers_loopback_forms
    [ "http://localhost:8080/r4", "http://127.0.0.1:8080/r4",
      "http://127.1.2.3:8080/r4", "http://[::1]:8080/r4",
      "http://[0:0:0:0:0:0:0:1]:8080/r4", "http://fhir.localhost:8080/r4" ].each do |url|
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

  # --- credential scope ---------------------------------------------------------
  #
  # The bearer token is for the configured FHIR base only. Search pagination
  # (#666) follows server-supplied next links, so the request layer itself
  # refuses to put a credential on any URL outside base_url's origin and path.

  def test_token_is_not_sent_to_a_foreign_origin
    assert_credential_refused("https://elsewhere.example.net/r4/Patient?page=2")
  end

  def test_token_is_not_sent_to_another_port_on_the_base_host
    assert_credential_refused("https://fhir.example.com:8443/r4/Patient?page=2")
  end

  def test_token_is_not_sent_outside_the_base_path
    assert_credential_refused("https://fhir.example.com/admin/Patient?page=2")
  end

  def test_token_is_not_sent_to_a_sibling_path_sharing_the_base_prefix
    assert_credential_refused("https://fhir.example.com/r4-internal/Patient")
  end

  def test_token_is_not_sent_to_a_dot_segment_path_escaping_the_base
    assert_credential_refused("https://fhir.example.com/r4/../admin/Patient")
  end

  def test_token_is_not_sent_to_userinfo_smuggled_host
    assert_credential_refused("https://fhir.example.com@elsewhere.example.net/r4/Patient")
  end

  def test_static_bearer_token_is_scoped_to_base_too
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, bearer_token: "static-tok")
    refuse_network(adapter)
    assert_raises(Corvid::Adapters::FhirAdapter::CredentialScopeError) do
      adapter.send(:execute_http, :get, "https://elsewhere.example.net/r4/Patient")
    end
  end

  def test_preset_authorization_header_is_scoped_to_base_too
    adapter = Corvid::Adapters::FhirAdapter.new(
      base_url: BASE, headers: { "Authorization" => "Bearer preset-tok" }
    )
    refuse_network(adapter)
    assert_raises(Corvid::Adapters::FhirAdapter::CredentialScopeError) do
      adapter.send(:execute_http, :get, "https://elsewhere.example.net/r4/Patient")
    end
  end

  # Refused before the source is consulted, so no grant is spent on it.
  def test_token_source_is_not_called_for_an_out_of_scope_url
    called = false
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, token_source: -> { called = true; "tok" })
    refuse_network(adapter)
    assert_raises(Corvid::Adapters::FhirAdapter::CredentialScopeError) do
      adapter.send(:execute_http, :get, "https://elsewhere.example.net/r4/Patient")
    end
    refute called
  end

  def test_credential_scope_error_omits_the_url
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, token_source: -> { "tok" })
    refuse_network(adapter)
    err = assert_raises(Corvid::Adapters::FhirAdapter::CredentialScopeError) do
      adapter.send(:execute_http, :get, "https://elsewhere.example.net/r4/Patient/pt-test-001")
    end
    refute_match(/pt_test_001|elsewhere/, err.message)
  end

  def test_unauthenticated_adapter_is_not_scope_checked
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE)
    req = capture_request(adapter, "https://elsewhere.example.net/r4/Patient")
    assert_nil req["Authorization"]
  end

  def test_in_scope_urls_still_carry_the_token
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, token_source: -> { "tok" })
    [ "#{BASE}/Patient?page=2", "https://FHIR.example.com/r4/Patient/1", "https://fhir.example.com:443/r4/Coverage" ].each do |url|
      assert_equal "Bearer tok", capture_request(adapter, url)["Authorization"], url
    end
  end

  # A paged search whose second page sits on the base path: every request
  # that goes out carries the token, and every one of them is under base.
  def test_paged_search_sends_the_token_only_under_base
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, token_source: -> { "tok" })
    page1 = { "resourceType" => "Bundle", "type" => "searchset",
              "link" => [ { "relation" => "next", "url" => "#{BASE}/Patient?page=2" } ], "entry" => [] }
    page2 = { "resourceType" => "Bundle", "type" => "searchset", "entry" => [] }
    sent = []
    fake_http = Object.new
    fake_http.define_singleton_method(:request) do |req|
      sent << [ req.uri.to_s, req["Authorization"] ]
      Net::HTTPOK.new("1.1", "200", "OK").tap do |resp|
        body = (sent.size == 1 ? page1 : page2).to_json
        resp.define_singleton_method(:body) { body }
      end
    end
    adapter.define_singleton_method(:build_http) { |_uri| fake_http }

    refute_nil adapter.send(:fhir_search, "Patient", { "name" => "TEST" })
    assert_equal 2, sent.size
    sent.each do |url, auth|
      assert url.start_with?("#{BASE}/"), url
      assert_equal "Bearer tok", auth
    end
  end

  # --- inspect -----------------------------------------------------------------
  #
  # Default #inspect renders every ivar, so an adapter in a log line, an error
  # tracker or a console would print the bearer token, or the token cached by
  # its token_source.

  def test_inspect_does_not_render_a_static_bearer_token
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, bearer_token: "synthetic-static-tok")
    refute_match(/synthetic-static-tok/, adapter.inspect)
    refute_match(/synthetic-static-tok/, adapter.pretty_inspect)
  end

  def test_inspect_does_not_render_a_preset_authorization_header
    adapter = Corvid::Adapters::FhirAdapter.new(
      base_url: BASE, headers: { "Authorization" => "Bearer synthetic-preset-tok" }
    )
    refute_match(/synthetic-preset-tok/, adapter.inspect)
  end

  def test_inspect_does_not_render_the_token_source
    source = Object.new
    source.define_singleton_method(:call) { "tok" }
    source.define_singleton_method(:inspect) { "#<Source cached=\"synthetic-cached-tok\">" }
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, token_source: source)
    refute_match(/synthetic-cached-tok/, adapter.inspect)
    assert_match(%r{fhir\.example\.com/r4}, adapter.inspect)
  end

  def test_request_carries_resolved_token_as_bearer_header
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, token_source: -> { "resolved-xyz" })
    assert_equal "Bearer resolved-xyz", capture_request(adapter, "#{BASE}/Patient/1")["Authorization"]
  end

  private

  def assert_credential_refused(url)
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, token_source: -> { "tok" })
    refuse_network(adapter)
    assert_raises(Corvid::Adapters::FhirAdapter::CredentialScopeError, url) do
      adapter.send(:execute_http, :get, url)
    end
  end

  def refuse_network(adapter)
    adapter.define_singleton_method(:build_http) { |_uri| raise "must not reach the network" }
  end

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
