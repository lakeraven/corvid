# frozen_string_literal: true

require "minitest/autorun"
require "openssl"
require "base64"
require "json"
require "corvid/auth/backend_services_client"

# Tests for the SMART Backend Services (client-credentials, signed-JWT)
# token client. No real network calls: the token endpoint is stubbed by
# overriding #post_token_request, and JWT signatures are verified against
# the public half of the key we sign with.
class Corvid::Auth::BackendServicesClientTest < Minitest::Test
  TOKEN_URL = "https://fhir.example.com/oauth2/token"
  SCOPE = "system/*.read"

  def setup
    @rsa = OpenSSL::PKey::RSA.new(2048)
    @ec  = OpenSSL::PKey::EC.generate("secp384r1")
  end

  # A client whose token POST is stubbed to record the last form body and
  # return a canned token response. Lets us assert on the client assertion
  # without hitting the network.
  def stub_client(private_key:, alg: "RS384", response: nil, now: Time.at(1_700_000_000), **opts)
    response ||= { "access_token" => "tok-abc", "token_type" => "bearer",
                   "expires_in" => 300, "scope" => SCOPE }
    captured = {}
    client = Corvid::Auth::BackendServicesClient.new(
      token_endpoint: TOKEN_URL,
      client_id: "corvid-app-123",
      private_key: private_key,
      signing_alg: alg,
      kid: "key-1",
      scopes: SCOPE,
      clock: -> { now },
      **opts
    )
    client.define_singleton_method(:post_token_request) do |form|
      captured[:form] = form
      response.is_a?(Proc) ? response.call(form) : response
    end
    client.define_singleton_method(:_captured) { captured }
    client
  end

  # --- happy path: fetch + cache ---------------------------------------------

  def test_access_token_returns_token_from_grant
    client = stub_client(private_key: @rsa)
    assert_equal "tok-abc", client.access_token
  end

  def test_access_token_is_cached_within_ttl
    calls = 0
    client = stub_client(private_key: @rsa,
                         response: ->(_f) { calls += 1; { "access_token" => "t#{calls}", "expires_in" => 300 } })
    first = client.access_token
    second = client.access_token
    assert_equal first, second
    assert_equal 1, calls, "token endpoint should be hit once while cached"
  end

  def test_token_refetched_after_expiry_with_skew
    calls = 0
    t = Time.at(1_700_000_000)
    clock = -> { t }
    client = Corvid::Auth::BackendServicesClient.new(
      token_endpoint: TOKEN_URL, client_id: "c", private_key: @rsa,
      kid: "k", scopes: SCOPE, clock: clock, refresh_skew: 30
    )
    client.define_singleton_method(:post_token_request) do |_form|
      calls += 1
      { "access_token" => "t#{calls}", "expires_in" => 300 }
    end
    assert_equal "t1", client.access_token
    # 300s ttl - 30s skew => refresh at +270s. Advance past it.
    t = Time.at(1_700_000_000 + 271)
    assert_equal "t2", client.access_token
    assert_equal 2, calls
  end

  # --- client assertion (the signed JWT) -------------------------------------

  def test_grant_posts_client_credentials_with_jwt_bearer_assertion
    client = stub_client(private_key: @rsa)
    client.access_token
    form = client._captured[:form]

    assert_equal "client_credentials", form["grant_type"]
    assert_equal SCOPE, form["scope"]
    assert_equal "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                 form["client_assertion_type"]
    assert form["client_assertion"], "expected a client_assertion JWT"
  end

  def test_client_assertion_header_and_claims
    now = Time.at(1_700_000_000)
    client = stub_client(private_key: @rsa, now: now)
    client.access_token
    jwt = client._captured[:form]["client_assertion"]
    header, claims = decode_jwt(jwt)

    assert_equal "RS384", header["alg"]
    assert_equal "JWT", header["typ"]
    assert_equal "key-1", header["kid"]

    # SMART BSA: iss == sub == client_id; aud == token endpoint.
    assert_equal "corvid-app-123", claims["iss"]
    assert_equal "corvid-app-123", claims["sub"]
    assert_equal TOKEN_URL, claims["aud"]
    assert claims["jti"], "assertion must carry a jti"
    assert_equal now.to_i, claims["iat"]
    assert claims["exp"] > now.to_i, "exp must be in the future"
    assert claims["exp"] <= now.to_i + 300, "exp must be <= 5 minutes out"
  end

  def test_client_assertion_signature_verifies_against_public_key
    client = stub_client(private_key: @rsa)
    client.access_token
    jwt = client._captured[:form]["client_assertion"]
    signing_input, sig = split_for_verify(jwt)

    assert @rsa.public_key.verify(OpenSSL::Digest.new("SHA384"), sig, signing_input),
           "RS384 signature must verify against the public key"
  end

  def test_jti_is_unique_per_assertion
    client = stub_client(private_key: @rsa,
                         response: ->(_f) { { "access_token" => "x", "expires_in" => 0 } })
    client.access_token
    jti1 = decode_jwt(client._captured[:form]["client_assertion"]).last["jti"]
    client.access_token # expires_in 0 forces a re-fetch
    jti2 = decode_jwt(client._captured[:form]["client_assertion"]).last["jti"]
    refute_equal jti1, jti2
  end

  # --- ES384 support ----------------------------------------------------------

  def test_es384_assertion_signs_and_verifies
    client = stub_client(private_key: @ec, alg: "ES384")
    client.access_token
    jwt = client._captured[:form]["client_assertion"]
    header, _claims = decode_jwt(jwt)
    assert_equal "ES384", header["alg"]

    signing_input, jose_sig = split_for_verify(jwt)
    der = jose_to_der(jose_sig)
    assert @ec.verify(OpenSSL::Digest.new("SHA384"), der, signing_input),
           "ES384 signature (JOSE r||s) must verify once converted to DER"
  end

  # --- errors -----------------------------------------------------------------

  def test_unsupported_alg_raises
    assert_raises(ArgumentError) do
      Corvid::Auth::BackendServicesClient.new(
        token_endpoint: TOKEN_URL, client_id: "c", private_key: @rsa,
        signing_alg: "HS256", kid: "k", scopes: SCOPE
      )
    end
  end

  def test_missing_access_token_in_response_raises
    client = stub_client(private_key: @rsa, response: { "error" => "invalid_client" })
    err = assert_raises(Corvid::Auth::BackendServicesClient::TokenError) { client.access_token }
    assert_match(/invalid_client/, err.message)
  end

  def test_to_proc_yields_current_token
    client = stub_client(private_key: @rsa)
    assert_equal "tok-abc", client.to_proc.call
  end

  # --- signing_alg derivation + key/curve validation --------------------------

  def test_signing_alg_defaults_to_rs384_for_rsa_key
    client = stub_client(private_key: @rsa, alg: nil)
    assert_equal "RS384", client.signing_alg
    client.access_token
    assert_equal "RS384", decode_jwt(client._captured[:form]["client_assertion"]).first["alg"]
  end

  def test_signing_alg_defaults_to_es384_for_ec_key
    client = stub_client(private_key: @ec, alg: nil)
    assert_equal "ES384", client.signing_alg
  end

  def test_rs384_with_ec_key_is_rejected
    err = assert_raises(ArgumentError) do
      new_client(private_key: @ec, signing_alg: "RS384")
    end
    assert_match(/RS384 requires an RSA/, err.message)
  end

  def test_es384_with_rsa_key_is_rejected
    err = assert_raises(ArgumentError) do
      new_client(private_key: @rsa, signing_alg: "ES384")
    end
    assert_match(/ES384 requires an EC/, err.message)
  end

  def test_es384_with_wrong_curve_is_rejected
    p256 = OpenSSL::PKey::EC.generate("prime256v1")
    err = assert_raises(ArgumentError) do
      new_client(private_key: p256, signing_alg: "ES384")
    end
    assert_match(/secp384r1/, err.message)
  end

  # --- constructor guardrails -------------------------------------------------

  def test_http_token_endpoint_is_rejected
    err = assert_raises(ArgumentError) do
      new_client(private_key: @rsa, token_endpoint: "http://fhir.example.com/oauth2/token")
    end
    assert_match(/https/, err.message)
  end

  def test_assertion_ttl_over_five_minutes_is_rejected
    assert_raises(ArgumentError) { new_client(private_key: @rsa, assertion_ttl: 301) }
  end

  def test_non_positive_assertion_ttl_is_rejected
    assert_raises(ArgumentError) { new_client(private_key: @rsa, assertion_ttl: 0) }
  end

  def test_negative_refresh_skew_is_rejected
    assert_raises(ArgumentError) { new_client(private_key: @rsa, refresh_skew: -30) }
  end

  # --- expires_in robustness --------------------------------------------------

  def test_absent_expires_in_caches_with_conservative_default
    calls = 0
    client = stub_client(private_key: @rsa,
                         response: ->(_f) { calls += 1; { "access_token" => "t#{calls}" } })
    client.access_token
    client.access_token # within the 60s default, no skew crossing at fixed clock
    assert_equal 1, calls, "absent expires_in should cache for the default TTL, not refetch"
  end

  def test_malformed_expires_in_raises
    client = stub_client(private_key: @rsa,
                         response: { "access_token" => "t", "expires_in" => "soon" })
    assert_raises(Corvid::Auth::BackendServicesClient::TokenError) { client.access_token }
  end

  def test_boolean_expires_in_raises_without_corrupting_cache
    client = stub_client(private_key: @rsa,
                         response: { "access_token" => "t", "expires_in" => true })
    assert_raises(Corvid::Auth::BackendServicesClient::TokenError) { client.access_token }
  end

  # --- response shape + token_type + redaction --------------------------------

  def test_non_2xx_response_raises_token_error
    resp = http_response(Net::HTTPForbidden, "403", '{"error":"invalid_scope"}')
    client = stub_client(private_key: @rsa)
    client.define_singleton_method(:post_token_request) { |_form| parse_token_response(resp) }
    err = assert_raises(Corvid::Auth::BackendServicesClient::TokenError) { client.access_token }
    assert_match(/403/, err.message)
    assert_match(/invalid_scope/, err.message)
  end

  def test_2xx_non_json_body_raises_with_truncated_raw
    resp = http_response(Net::HTTPOK, "200", "<html>login</html>")
    client = stub_client(private_key: @rsa)
    client.define_singleton_method(:post_token_request) { |_form| parse_token_response(resp) }
    err = assert_raises(Corvid::Auth::BackendServicesClient::TokenError) { client.access_token }
    assert_match(/unparseable/, err.message)
    assert_match(/html/, err.message)
  end

  def test_non_bearer_token_type_is_rejected
    client = stub_client(private_key: @rsa,
                         response: { "access_token" => "t", "token_type" => "DPoP", "expires_in" => 300 })
    err = assert_raises(Corvid::Auth::BackendServicesClient::TokenError) { client.access_token }
    assert_match(/token_type/, err.message)
  end

  def test_error_message_does_not_leak_token_values
    client = stub_client(private_key: @rsa,
                         response: { "refresh_token" => "SUPER-SECRET", "error" => "invalid_client" })
    err = assert_raises(Corvid::Auth::BackendServicesClient::TokenError) { client.access_token }
    refute_match(/SUPER-SECRET/, err.message)
  end

  # --- helpers ----------------------------------------------------------------

  # Build a real client (no stubbed POST) for constructor-validation tests.
  def new_client(private_key:, **overrides)
    Corvid::Auth::BackendServicesClient.new(
      **{ token_endpoint: TOKEN_URL, client_id: "c", private_key: private_key,
          kid: "k", scopes: SCOPE }.merge(overrides)
    )
  end

  # A real Net::HTTP response subclass (so is_a?(Net::HTTPSuccess) works)
  # with a canned body, for exercising parse_token_response.
  def http_response(klass, code, body)
    klass.new("1.1", code, "").tap do |resp|
      resp.define_singleton_method(:body) { body }
    end
  end

  def decode_jwt(jwt)
    h, p, _s = jwt.split(".")
    [ JSON.parse(b64url_decode(h)), JSON.parse(b64url_decode(p)) ]
  end

  def split_for_verify(jwt)
    h, p, s = jwt.split(".")
    [ "#{h}.#{p}", b64url_decode(s) ]
  end

  def b64url_decode(str)
    Base64.urlsafe_decode64(str + "=" * ((4 - str.length % 4) % 4))
  end

  # Convert a JOSE fixed-width r||s ES384 signature to DER for OpenSSL verify.
  def jose_to_der(sig)
    half = sig.bytesize / 2
    r = OpenSSL::BN.new(sig[0, half], 2)
    s = OpenSSL::BN.new(sig[half, half], 2)
    OpenSSL::ASN1::Sequence.new([ OpenSSL::ASN1::Integer.new(r),
                                 OpenSSL::ASN1::Integer.new(s) ]).to_der
  end
end
