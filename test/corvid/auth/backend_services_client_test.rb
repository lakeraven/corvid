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
  def stub_client(private_key:, alg: "RS384", response: nil, now: Time.at(1_700_000_000),
                  clock: nil, **opts)
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
      clock: clock || -> { now },
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
    t = Time.at(1_700_000_000)
    client = stub_client(private_key: @rsa, clock: -> { t },
                         response: ->(_f) { { "access_token" => "x", "expires_in" => 60 } })
    client.access_token
    jti1 = decode_jwt(client._captured[:form]["client_assertion"]).last["jti"]
    t = Time.at(1_700_000_000 + 120) # past expiry: forces a re-fetch
    client.access_token
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

  # --- key strength: private half + modern size -------------------------------

  def test_rsa_public_key_is_rejected
    public_only = OpenSSL::PKey::RSA.new(@rsa.public_key.to_pem)
    refute public_only.private?, "fixture must be public-only"
    err = assert_raises(ArgumentError) { new_client(private_key: public_only) }
    assert_match(/PRIVATE/, err.message)
  end

  def test_ec_public_key_is_rejected
    public_only = OpenSSL::PKey::EC.new(@ec.public_to_pem)
    refute public_only.private?, "fixture must be public-only"
    err = assert_raises(ArgumentError) { new_client(private_key: public_only) }
    assert_match(/PRIVATE/, err.message)
  end

  def test_undersized_rsa_key_is_rejected
    weak = OpenSSL::PKey::RSA.new(1024)
    err = assert_raises(ArgumentError) { new_client(private_key: weak) }
    assert_match(/2048/, err.message)
    assert_match(/1024/, err.message)
  end

  def test_2048_bit_rsa_key_is_accepted
    assert_equal "RS384", new_client(private_key: @rsa).signing_alg
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
    assert_cache_untouched(client)
  end

  # An expires_in of 0 (or negative) means the token is already dead. Caching
  # it would hand out one guaranteed-401 token per grant, so the grant fails.

  def test_zero_expires_in_raises_without_corrupting_cache
    client = stub_client(private_key: @rsa,
                         response: { "access_token" => "t", "expires_in" => 0 })
    err = assert_raises(Corvid::Auth::BackendServicesClient::TokenError) { client.access_token }
    assert_match(/expires_in/, err.message)
    assert_cache_untouched(client)
  end

  def test_negative_expires_in_raises_without_corrupting_cache
    client = stub_client(private_key: @rsa,
                         response: { "access_token" => "t", "expires_in" => -300 })
    assert_raises(Corvid::Auth::BackendServicesClient::TokenError) { client.access_token }
    assert_cache_untouched(client)
  end

  def test_fractional_expires_in_below_one_second_raises
    client = stub_client(private_key: @rsa,
                         response: { "access_token" => "t", "expires_in" => 0.4 })
    assert_raises(Corvid::Auth::BackendServicesClient::TokenError) { client.access_token }
    assert_cache_untouched(client)
  end

  # --- blank access_token ------------------------------------------------------

  # " " survives a bare empty? check but becomes a malformed "Bearer  "
  # header: every call 401s and the outage looks like missing data.
  def test_whitespace_only_access_token_is_rejected_and_not_cached
    client = stub_client(private_key: @rsa,
                         response: { "access_token" => "   ", "expires_in" => 300 })
    err = assert_raises(Corvid::Auth::BackendServicesClient::TokenError) { client.access_token }
    assert_match(/blank access_token/, err.message)
    assert_cache_untouched(client)
  end

  def test_empty_access_token_is_rejected
    client = stub_client(private_key: @rsa,
                         response: { "access_token" => "", "expires_in" => 300 })
    assert_raises(Corvid::Auth::BackendServicesClient::TokenError) { client.access_token }
    assert_cache_untouched(client)
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

  def test_2xx_non_json_body_raises_without_echoing_the_body
    resp = http_response(Net::HTTPOK, "200", "<html>login access_token=LEAKED-TOKEN</html>")
    client = stub_client(private_key: @rsa)
    client.define_singleton_method(:post_token_request) { |_form| parse_token_response(resp) }
    err = assert_raises(Corvid::Auth::BackendServicesClient::TokenError) { client.access_token }
    assert_match(/unparseable/, err.message)
    assert_match(/bytes/, err.message, "expected a body-free size summary")
    refute_match(/LEAKED-TOKEN/, err.message)
    refute_match(/html/, err.message)
  end

  # --- credential redaction: no response body ever reaches the message --------

  # A form-encoded 200 (some servers do this) parses as neither JSON object
  # nor JSON scalar — echoing it verbatim would log a live access token.
  def test_form_encoded_success_body_is_not_echoed
    resp = http_response(Net::HTTPOK, "200", "access_token=LIVE-TOKEN-abc&token_type=bearer")
    client = stub_client(private_key: @rsa)
    client.define_singleton_method(:post_token_request) { |_form| parse_token_response(resp) }
    err = assert_raises(Corvid::Auth::BackendServicesClient::TokenError) { client.access_token }
    refute_match(/LIVE-TOKEN-abc/, err.message)
  end

  # A bare JSON string parses fine but is not an object; the string itself
  # may be the token.
  def test_json_scalar_success_body_is_not_echoed
    resp = http_response(Net::HTTPOK, "200", '"LIVE-TOKEN-xyz"')
    client = stub_client(private_key: @rsa)
    client.define_singleton_method(:post_token_request) { |_form| parse_token_response(resp) }
    err = assert_raises(Corvid::Auth::BackendServicesClient::TokenError) { client.access_token }
    assert_match(/non-object/, err.message)
    refute_match(/LIVE-TOKEN-xyz/, err.message)
  end

  # A 5xx that echoes the request (including our signed client assertion)
  # must not put JWT material in the exception.
  def test_5xx_echoing_the_assertion_is_not_echoed
    body = "500 Internal Error: client_assertion=eyJhbGciOiJSUzM4NCJ9.SIGNED-ASSERTION.sig"
    resp = http_response(Net::HTTPInternalServerError, "500", body)
    client = stub_client(private_key: @rsa)
    client.define_singleton_method(:post_token_request) { |_form| parse_token_response(resp) }
    err = assert_raises(Corvid::Auth::BackendServicesClient::TokenError) { client.access_token }
    assert_match(/500/, err.message)
    refute_match(/SIGNED-ASSERTION/, err.message)
    refute_match(/eyJ/, err.message)
  end

  # error_description is free text under the server's control and has been
  # seen to echo the submitted assertion.
  def test_oauth_error_description_is_summarized_not_quoted
    client = stub_client(
      private_key: @rsa,
      response: { "error" => "invalid_client",
                  "error_description" => "assertion eyJhbGciOiJSUzM4NCJ9.SECRET rejected" }
    )
    err = assert_raises(Corvid::Auth::BackendServicesClient::TokenError) { client.access_token }
    assert_match(/invalid_client/, err.message)
    assert_match(/redacted/, err.message)
    refute_match(/SECRET/, err.message)
  end

  def test_non_registry_error_code_is_redacted
    client = stub_client(private_key: @rsa,
                         response: { "error" => "token eyJhbGciOiJSUzM4NCJ9.SECRET is bad" })
    err = assert_raises(Corvid::Auth::BackendServicesClient::TokenError) { client.access_token }
    refute_match(/SECRET/, err.message)
  end

  # --- TLS on the real token request ------------------------------------------

  # Exercises the actual post_token_request path (no stubbing it away):
  # only the socket-level #request is replaced, so the Net::HTTP the client
  # would really use is inspected.
  def test_token_request_uses_tls_with_peer_verification
    canned = http_response(Net::HTTPOK, "200",
                           '{"access_token":"t","token_type":"bearer","expires_in":300}')
    client = new_client(private_key: @rsa)
    built = nil
    client.define_singleton_method(:build_http) do |uri|
      built = super(uri)
      built.define_singleton_method(:request) { |_req| canned }
      built
    end

    assert_equal "t", client.access_token
    assert built.use_ssl?, "token request must use TLS"
    assert_equal OpenSSL::SSL::VERIFY_PEER, built.verify_mode,
                 "token request must verify the server certificate"
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

  # A rejected grant must leave no trace in the cache — neither a token
  # without an expiry nor an expiry without a token.
  def assert_cache_untouched(client)
    assert_nil client.instance_variable_get(:@cached_token), "cache must hold no token"
    assert_nil client.instance_variable_get(:@expires_at), "cache must hold no expiry"
  end

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
