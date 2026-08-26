# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "base64"
require "securerandom"
require "openssl"

module Corvid
  module Auth
    # SMART Backend Services token client (ONC (g)(10) "system-to-system").
    #
    # Performs the OAuth2 *client-credentials* grant using a signed-JWT
    # client assertion, per the SMART App Launch "Backend Services"
    # profile. Given a private signing key and the vendor's token endpoint,
    # it returns short-lived bearer tokens and caches them until they are
    # near expiry. The paired public key is published at a JWKS URL the
    # vendor is registered against — hosting that endpoint and holding the
    # private key are the deployment's job (corvid-saas), not this client's.
    #
    # This object is stateless with respect to PHI and stores no secrets of
    # its own: the private key is injected by the caller. It is the auth
    # companion to Corvid::Adapters::FhirAdapter — wire it in via that
    # adapter's +token_source:+ keyword so every request carries a fresh
    # token:
    #
    #   client = Corvid::Auth::BackendServicesClient.new(
    #     token_endpoint: "https://fhir.vendor.example/oauth2/token",
    #     client_id:      registered_client_id,
    #     private_key:    OpenSSL::PKey::RSA.new(pem),
    #     kid:            "key-1",
    #     scopes:         "system/Patient.read system/Observation.read"
    #   )
    #   Corvid::Adapters::FhirAdapter.new(base_url: url, token_source: client)
    #
    # Only the two JOSE algorithms the SMART Backend Services spec requires
    # servers to support are offered: RS384 (RSA keys) and ES384 (P-384 EC
    # keys). The client picks per its key type.
    class BackendServicesClient
      # Raised when the token endpoint does not return a usable access token.
      class TokenError < StandardError; end

      GRANT_TYPE = "client_credentials"
      ASSERTION_TYPE = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

      # JOSE alg => OpenSSL digest. These are the algs SMART Backend
      # Services mandates; anything else is rejected up front.
      SUPPORTED_ALGS = {
        "RS384" => "SHA384",
        "ES384" => "SHA384"
      }.freeze

      # Client-assertion lifetime. The spec caps this at 5 minutes; we sign
      # short-lived assertions to limit the replay window.
      ASSERTION_TTL = 300

      # Seconds before a cached access token's stated expiry at which we
      # proactively refetch, so an in-flight request never rides an
      # about-to-expire token.
      DEFAULT_REFRESH_SKEW = 30

      DEFAULT_OPEN_TIMEOUT = 10
      DEFAULT_READ_TIMEOUT = 30

      attr_reader :token_endpoint, :client_id, :scopes, :signing_alg, :kid

      def initialize(token_endpoint:, client_id:, private_key:, kid:, scopes:,
                     signing_alg: "RS384",
                     refresh_skew: DEFAULT_REFRESH_SKEW,
                     assertion_ttl: ASSERTION_TTL,
                     clock: -> { Time.now },
                     open_timeout: DEFAULT_OPEN_TIMEOUT,
                     read_timeout: DEFAULT_READ_TIMEOUT)
        unless SUPPORTED_ALGS.key?(signing_alg)
          raise ArgumentError,
                "unsupported signing_alg #{signing_alg.inspect}; " \
                "SMART Backend Services allows #{SUPPORTED_ALGS.keys.join(', ')}"
        end

        @token_endpoint = token_endpoint
        @client_id = client_id
        @private_key = private_key
        @kid = kid
        @scopes = scopes
        @signing_alg = signing_alg
        @refresh_skew = refresh_skew
        @assertion_ttl = assertion_ttl
        @clock = clock
        @open_timeout = open_timeout
        @read_timeout = read_timeout

        @cached_token = nil
        @expires_at = nil
      end

      # Return a valid bearer token, fetching a new one via the grant if the
      # cache is empty or within +refresh_skew+ of expiry.
      def access_token
        return @cached_token if token_fresh?

        grant = request_grant
        token = grant["access_token"]
        unless token.is_a?(String) && !token.empty?
          raise TokenError,
                "token endpoint returned no access_token " \
                "(response: #{grant.inspect})"
        end

        # Honor the stated lifetime, including expires_in: 0 (expired now).
        # An absent expires_in => 0 => never cached: safest, since we can't
        # assume how long an unspecified token stays valid.
        @cached_token = token
        @expires_at = now.to_i + grant["expires_in"].to_i
        token
      end

      # Callable form so the token client can be handed straight to
      # FhirAdapter(token_source:) — it invokes +.call+ per request.
      def call
        access_token
      end

      def to_proc
        method(:call).to_proc
      end

      private

      def now
        @clock.call
      end

      def token_fresh?
        return false if @cached_token.nil?
        now.to_i < (@expires_at - @refresh_skew)
      end

      # Run the client-credentials grant and return the parsed JSON body.
      def request_grant
        post_token_request(
          "grant_type" => GRANT_TYPE,
          "scope" => @scopes,
          "client_assertion_type" => ASSERTION_TYPE,
          "client_assertion" => build_client_assertion
        )
      end

      # POST the form to the token endpoint and return the parsed response.
      # Isolated so it can be stubbed in tests without real network calls.
      def post_token_request(form)
        uri = URI.parse(@token_endpoint)
        request = Net::HTTP::Post.new(uri)
        request["Accept"] = "application/json"
        request.set_form_data(form)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        response = http.request(request)

        parse_token_response(response)
      end

      def parse_token_response(response)
        body = begin
          JSON.parse(response.body.to_s)
        rescue JSON::ParserError
          {}
        end
        unless response.is_a?(Net::HTTPSuccess)
          raise TokenError,
                "token endpoint returned HTTP #{response.code}: " \
                "#{body.empty? ? response.body : body.inspect}"
        end
        body
      end

      # Build and sign the JWT client assertion. Per SMART Backend Services:
      # iss == sub == client_id, aud == token endpoint, unique jti, and a
      # short expiry.
      def build_client_assertion
        issued = now.to_i
        header = { "alg" => @signing_alg, "typ" => "JWT", "kid" => @kid }
        claims = {
          "iss" => @client_id,
          "sub" => @client_id,
          "aud" => @token_endpoint,
          "jti" => SecureRandom.uuid,
          "iat" => issued,
          "exp" => issued + @assertion_ttl
        }

        signing_input = "#{b64url(JSON.generate(header))}.#{b64url(JSON.generate(claims))}"
        "#{signing_input}.#{b64url(sign(signing_input))}"
      end

      def sign(signing_input)
        digest = OpenSSL::Digest.new(SUPPORTED_ALGS.fetch(@signing_alg))
        der = @private_key.sign(digest, signing_input)
        # RSA (RS*) signatures are already in the JOSE wire format; ECDSA
        # (ES*) signatures come back DER-encoded and must be converted to
        # the fixed-width r||s form JOSE requires.
        @signing_alg.start_with?("ES") ? der_to_jose(der) : der
      end

      # Convert a DER-encoded ECDSA signature to JOSE fixed-width r||s.
      # ES384 => 48-byte components (P-384).
      def der_to_jose(der)
        asn1 = OpenSSL::ASN1.decode(der)
        r = asn1.value[0].value
        s = asn1.value[1].value
        size = ec_component_bytes
        pad(r, size) + pad(s, size)
      end

      def ec_component_bytes
        # ceil(field_bits / 8); ES384 uses P-384.
        48
      end

      def pad(bn, size)
        bytes = bn.to_s(2) # OpenSSL::BN => big-endian binary, no leading zeros
        raise TokenError, "ECDSA component too large for #{size} bytes" if bytes.bytesize > size
        bytes.rjust(size, "\x00".b)
      end

      def b64url(bytes)
        Base64.urlsafe_encode64(bytes, padding: false)
      end
    end
  end
end
