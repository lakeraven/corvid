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
    # keys). The signing algorithm is derived from the key type unless
    # +signing_alg:+ is given explicitly; either way the key type and curve
    # are validated to match, so a mislabelled key fails fast here rather
    # than producing a signature the vendor silently rejects. The instance
    # is safe to share across threads.
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

      # Maximum client-assertion lifetime; the SMART spec caps this at 5
      # minutes. Also the default — we sign short-lived assertions to limit
      # the replay window.
      MAX_ASSERTION_TTL = 300

      # Seconds before a cached access token's stated expiry at which we
      # proactively refetch, so an in-flight request never rides an
      # about-to-expire token.
      DEFAULT_REFRESH_SKEW = 30

      # Conservative cache lifetime used when the token endpoint omits
      # expires_in (it is only RECOMMENDED by OAuth2). Long enough to avoid
      # a fresh grant on every FHIR call, short enough to bound the blast
      # radius of an unknown real lifetime.
      DEFAULT_TOKEN_TTL = 60

      DEFAULT_OPEN_TIMEOUT = 10
      DEFAULT_READ_TIMEOUT = 30

      attr_reader :token_endpoint, :client_id, :scopes, :signing_alg, :kid

      def initialize(token_endpoint:, client_id:, private_key:, kid:, scopes:,
                     signing_alg: nil,
                     refresh_skew: DEFAULT_REFRESH_SKEW,
                     assertion_ttl: MAX_ASSERTION_TTL,
                     clock: -> { Time.now },
                     open_timeout: DEFAULT_OPEN_TIMEOUT,
                     read_timeout: DEFAULT_READ_TIMEOUT,
                     ca_file: nil,
                     ca_path: nil)
        @token_endpoint = require_https!(token_endpoint)
        alg = signing_alg || derive_alg(private_key)
        unless SUPPORTED_ALGS.key?(alg)
          raise ArgumentError,
                "unsupported signing_alg #{alg.inspect}; " \
                "SMART Backend Services allows #{SUPPORTED_ALGS.keys.join(', ')}"
        end
        validate_key_for_alg!(alg, private_key)
        validate_assertion_ttl!(assertion_ttl)
        validate_refresh_skew!(refresh_skew)

        @client_id = client_id
        @private_key = private_key
        @kid = kid
        @scopes = scopes
        @signing_alg = alg
        @refresh_skew = refresh_skew
        @assertion_ttl = assertion_ttl
        @clock = clock
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @ca_file = ca_file
        @ca_path = ca_path

        @mutex = Mutex.new
        @cached_token = nil
        @expires_at = nil
      end

      # Return a valid bearer token, fetching a new one via the grant if the
      # cache is empty or within +refresh_skew+ of expiry. The fetch runs
      # under a mutex, so concurrent callers coalesce onto a single grant
      # (no token-endpoint stampede) and never observe a torn token/expiry.
      def access_token
        @mutex.synchronize do
          return @cached_token if token_fresh?

          grant = request_grant
          token = extract_access_token(grant)
          validate_token_type!(grant)
          ttl = ttl_from(grant)

          # Assign only after every check passes, so a malformed response
          # can never leave a half-updated cache.
          @cached_token = token
          @expires_at = now.to_i + ttl
          token
        end
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

      # --- construction-time validation -------------------------------------

      def require_https!(endpoint)
        scheme = URI.parse(endpoint).scheme
        unless scheme == "https"
          raise ArgumentError,
                "token_endpoint must use https (SMART Backend Services " \
                "requires TLS), got #{scheme.inspect}"
        end
        endpoint
      rescue URI::InvalidURIError => e
        raise ArgumentError, "invalid token_endpoint: #{e.message}"
      end

      def derive_alg(key)
        case key
        when OpenSSL::PKey::RSA then "RS384"
        when OpenSSL::PKey::EC  then "ES384"
        else
          raise ArgumentError,
                "cannot derive signing_alg from #{key.class}; " \
                "supply an RSA (RS384) or P-384 EC (ES384) private key"
        end
      end

      def validate_key_for_alg!(alg, key)
        case alg
        when "RS384"
          unless key.is_a?(OpenSSL::PKey::RSA)
            raise ArgumentError, "RS384 requires an RSA private key, got #{key.class}"
          end
        when "ES384"
          unless key.is_a?(OpenSSL::PKey::EC)
            raise ArgumentError, "ES384 requires an EC (P-384) private key, got #{key.class}"
          end
          curve = key.group.curve_name
          unless curve == "secp384r1"
            raise ArgumentError,
                  "ES384 requires a P-384 (secp384r1) key, got curve #{curve.inspect}"
          end
        end
      end

      def validate_assertion_ttl!(ttl)
        return if ttl.is_a?(Integer) && ttl.between?(1, MAX_ASSERTION_TTL)

        raise ArgumentError,
              "assertion_ttl must be an integer in 1..#{MAX_ASSERTION_TTL} " \
              "(SMART caps assertions at 5 minutes), got #{ttl.inspect}"
      end

      def validate_refresh_skew!(skew)
        return if skew.is_a?(Numeric) && skew >= 0

        raise ArgumentError,
              "refresh_skew must be a non-negative number, got #{skew.inspect}"
      end

      # --- grant + response ------------------------------------------------

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
        http.ca_file = @ca_file if @ca_file
        http.ca_path = @ca_path if @ca_path
        response = http.request(request)

        parse_token_response(response)
      end

      def parse_token_response(response)
        raw = response.body.to_s
        parsed = begin
          JSON.parse(raw)
        rescue JSON::ParserError
          :unparseable
        end

        unless response.is_a?(Net::HTTPSuccess)
          detail = parsed == :unparseable ? truncate(raw) : oauth_detail(parsed)
          raise TokenError, "token endpoint returned HTTP #{response.code}: #{detail}"
        end

        if parsed == :unparseable
          raise TokenError,
                "token endpoint returned #{response.code} with an unparseable body: #{truncate(raw)}"
        end
        unless parsed.is_a?(Hash)
          raise TokenError,
                "token endpoint returned #{response.code} with a non-object JSON body: #{truncate(raw)}"
        end
        parsed
      end

      def extract_access_token(grant)
        token = grant["access_token"]
        return token if token.is_a?(String) && !token.empty?

        raise TokenError, "token endpoint returned no access_token (#{oauth_detail(grant)})"
      end

      # Many servers omit token_type; tolerate that, but reject a response
      # that explicitly asks for a non-Bearer scheme (DPoP/MAC) we would
      # otherwise silently send as Bearer.
      def validate_token_type!(grant)
        type = grant["token_type"]
        return if type.nil? || type.to_s.casecmp?("bearer")

        raise TokenError,
              "token endpoint returned unsupported token_type #{type.inspect}; " \
              "only Bearer is supported"
      end

      # Resolve the cache lifetime from expires_in. Absent => a conservative
      # default (avoid a grant per request); non-numeric/garbage => a hard
      # error (a broken response, not a silent 0). Non-positive values leave
      # the token immediately stale so the next call refetches.
      def ttl_from(grant)
        raw = grant["expires_in"]
        return DEFAULT_TOKEN_TTL if raw.nil?

        ttl = case raw
        when Integer then raw
        when Float then raw.to_i
        when String then Integer(raw, exception: false)
        end
        raise TokenError, "token endpoint returned malformed expires_in #{raw.inspect}" if ttl.nil?

        ttl
      end

      # Redact token-endpoint bodies to the OAuth error fields (or just the
      # key names), so an access/refresh token or echoed assertion in a
      # nonconforming response never lands in an exception message or log.
      def oauth_detail(body)
        return "non-object response" unless body.is_a?(Hash)

        described = body.values_at("error", "error_description").compact
        return described.join(": ") unless described.empty?

        "response keys: #{body.keys.sort.join(', ')}"
      end

      def truncate(str, limit = 300)
        s = str.to_s
        s.length > limit ? "#{s[0, limit]}…(truncated)" : s
      end

      # --- JWT client assertion --------------------------------------------

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

      # Convert a DER-encoded ECDSA signature to JOSE fixed-width r||s. The
      # component width comes from the key's curve (48 bytes for the
      # validated P-384 key), never a hardcoded guess.
      def der_to_jose(der)
        asn1 = OpenSSL::ASN1.decode(der)
        size = (@private_key.group.degree + 7) / 8
        pad(asn1.value[0].value, size) + pad(asn1.value[1].value, size)
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
