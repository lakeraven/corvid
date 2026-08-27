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

  def test_request_carries_resolved_token_as_bearer_header
    adapter = Corvid::Adapters::FhirAdapter.new(base_url: BASE, token_source: -> { "resolved-xyz" })
    captured = nil
    # Intercept at the network boundary so no real call is made; capture
    # the request that would have gone out.
    fake_http = Object.new
    fake_http.define_singleton_method(:request) do |req|
      captured = req
      Net::HTTPOK.new("1.1", "200", "OK")
    end
    adapter.define_singleton_method(:build_http) { |_uri| fake_http }

    adapter.send(:execute_http, :get, "#{BASE}/Patient/1")
    assert_equal "Bearer resolved-xyz", captured["Authorization"]
  end
end
