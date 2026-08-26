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

  # --- helpers ----------------------------------------------------------------

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
