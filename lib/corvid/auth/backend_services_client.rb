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
    # than producing a signature the vendor silently rejects. The key must
    # be a private key of adequate strength (RSA >= 2048 bits). The instance
    # is safe to share across threads.
    #
    # Nothing derived from a token-endpoint response body is ever placed in
    # an exception message: a nonconforming endpoint can return a token, or
    # echo our signed assertion, in a body of any shape, and TokenError
    # messages reach application logs.
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

      # Smallest RSA modulus accepted for RS384 signing. 2048 is the floor
      # every current guideline (NIST SP 800-57, BCP 195) puts on RSA; a
      # shorter key would be silently accepted by many token endpoints while
      # offering materially less protection for the assertion signature.
      MIN_RSA_KEY_BITS = 2048

      # Response-derived strings are never echoed except when they match one
      # of these protocol constants, which carry no data. Everything else is
      # reported by shape — see #describe_response_value.
      KNOWN_TOKEN_TYPES = %w[Bearer DPoP MAC Basic Negotiate N_A].freeze

      # RFC 6749 §5.2 + RFC 6750 §3.1 error codes.
      KNOWN_ERROR_CODES = %w[
        invalid_request invalid_client invalid_grant unauthorized_client
        unsupported_grant_type invalid_scope invalid_token insufficient_scope
        server_error temporarily_unavailable
      ].freeze

      # Recognized OAuth2 token-response fields, for summarizing a response
      # by which known keys it carried without naming unknown ones.
      KNOWN_GRANT_KEYS = %w[
        access_token token_type expires_in scope refresh_token id_token
        error error_description error_uri issued_token_type
      ].freeze

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
        # dup+freeze: validating the caller's string is worthless if the
        # caller (or anyone holding the attr_reader's return value) can
        # mutate it to http:// afterwards and steer the signed assertion
        # onto a cleartext connection. The scheme is re-checked per request
        # as well — see #post_token_request.
        @token_endpoint = require_https!(token_endpoint).dup.freeze
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

      # Validate the signing key beyond its class: it must be a *private*
      # key (a public half cannot sign, and would otherwise fail deep inside
      # the first grant as an opaque OpenSSL error) and, for RSA, of a
      # modern size.
      def validate_key_for_alg!(alg, key)
        case alg
        when "RS384"
          unless key.is_a?(OpenSSL::PKey::RSA)
            raise ArgumentError, "RS384 requires an RSA private key, got #{key.class}"
          end
          require_private_key!(key, "RS384")
          bits = key.n&.num_bits.to_i
          if bits < MIN_RSA_KEY_BITS
            raise ArgumentError,
                  "RS384 requires an RSA key of at least #{MIN_RSA_KEY_BITS} bits, " \
                  "got #{bits}"
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
          require_private_key!(key, "ES384")
        end
      end

      def require_private_key!(key, alg)
        return if key.private?

        raise ArgumentError,
              "#{alg} requires a PRIVATE key; the supplied #{key.class} carries " \
              "only a public half and cannot sign the client assertion"
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
        # Re-validated here, not just at construction: this is the point
        # where the signed assertion goes on the wire.
        uri = URI.parse(require_https!(@token_endpoint))
        request = Net::HTTP::Post.new(uri)
        request["Accept"] = "application/json"
        request.set_form_data(form)

        parse_token_response(build_http(uri).request(request))
      end

      # Construct the Net::HTTP used for the grant. TLS with peer
      # verification is set explicitly rather than left to Net::HTTP's
      # default, so the setting is visible, testable, and cannot drift: this
      # request carries a signed assertion out and a bearer token back.
      def build_http(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        http.ca_file = @ca_file if @ca_file
        http.ca_path = @ca_path if @ca_path
        http
      end

      # Parse the grant response. Nothing derived from the response *body*
      # is ever interpolated into an exception: a nonconforming endpoint can
      # put an access token, a refresh token, or an echo of our signed
      # assertion in a body of any shape (a bare JSON string, form-encoding,
      # a 5xx debug dump), and TokenError messages land in Rails logs.
      # Diagnostics come from a safe summary instead.
      def parse_token_response(response)
        raw = response.body.to_s
        parsed = begin
          JSON.parse(raw)
        rescue JSON::ParserError
          :unparseable
        end

        unless response.is_a?(Net::HTTPSuccess)
          detail = parsed.is_a?(Hash) ? oauth_detail(parsed) : response_summary(response, raw)
          raise TokenError, "token endpoint returned HTTP #{response.code}: #{detail}"
        end

        if parsed == :unparseable
          raise TokenError,
                "token endpoint returned #{response.code} with an unparseable body " \
                "(#{response_summary(response, raw)})"
        end
        unless parsed.is_a?(Hash)
          raise TokenError,
                "token endpoint returned #{response.code} with a non-object JSON body " \
                "(#{response_summary(response, raw)})"
        end
        parsed
      end

      def extract_access_token(grant)
        token = grant["access_token"]
        return token if token.is_a?(String) && !token.strip.empty?

        if token.is_a?(String)
          # Whitespace-only passes a bare empty? check but would be emitted
          # as a malformed "Bearer  " header: every subsequent call 401s and
          # the failure presents as missing data, not as broken auth.
          raise TokenError,
                "token endpoint returned a blank access_token " \
                "(#{token.length} whitespace characters)"
        end

        raise TokenError, "token endpoint returned no access_token (#{oauth_detail(grant)})"
      end

      # Many servers omit token_type; tolerate that, but reject a response
      # that explicitly asks for a non-Bearer scheme (DPoP/MAC) we would
      # otherwise silently send as Bearer.
      def validate_token_type!(grant)
        type = grant["token_type"]
        return if type.nil?
        return if type.is_a?(String) && type.casecmp?("bearer")

        raise TokenError,
              "token endpoint returned unsupported token_type " \
              "(#{describe_response_value(type, allow: KNOWN_TOKEN_TYPES)}); " \
              "only Bearer is supported"
      end

      # Resolve the cache lifetime from expires_in. Absent => a conservative
      # default (avoid a grant per request); anything else must be a
      # *positive* number. A zero/negative lifetime means the endpoint handed
      # us an already-expired token: caching it would serve one guaranteed
      # 401 per grant, so the grant is failed instead. Booleans and other
      # non-numeric garbage are a broken response, not a silent 0.
      def ttl_from(grant)
        raw = grant["expires_in"]
        return DEFAULT_TOKEN_TTL if raw.nil?

        ttl = case raw
        when true, false then nil
        when Integer then raw
        when Float then raw.to_i
        when String then Integer(raw, exception: false)
        end
        if ttl.nil?
          raise TokenError,
                "token endpoint returned malformed expires_in " \
                "(#{describe_response_value(raw)})"
        end

        if ttl <= 0
          # ttl is a parsed integer here, so echoing it carries no response
          # text — unlike the raw field, which is attacker-controlled.
          raise TokenError,
                "token endpoint returned non-positive expires_in (#{ttl} seconds); " \
                "the access token is already expired"
        end

        ttl
      end

      # Redact token-endpoint bodies to the OAuth error *code* (or just the
      # key names), so an access/refresh token or an echoed assertion in a
      # nonconforming response never lands in an exception message or log.
      # error_description is free text the server controls and has been seen
      # to echo the submitted assertion, so it is summarized, never quoted.
      def oauth_detail(body)
        return "non-object response" unless body.is_a?(Hash)

        code = body["error"]
        parts = []
        parts << "error=#{safe_error_code(code)}" unless code.nil?
        parts << "error_description present (redacted)" if body["error_description"]
        return parts.join("; ") unless parts.empty?

        # Key NAMES are response-derived too: a nonconforming endpoint can
        # put credential material in a key. Only recognized OAuth2 fields
        # are named; the rest are counted.
        known = (body.keys & KNOWN_GRANT_KEYS).sort
        unknown = body.keys.length - known.length
        summary = []
        summary << "known keys: #{known.join(', ')}" unless known.empty?
        summary << "#{unknown} unrecognized key(s)" if unknown.positive?
        summary.empty? ? "empty response object" : summary.join("; ")
      end

      # OAuth2 error codes are short registry tokens; anything else in that
      # field is a server going off-spec and is not repeated verbatim.
      def safe_error_code(code)
        code.is_a?(String) && KNOWN_ERROR_CODES.include?(code) ? code : "(redacted)"
      end

      # Describe a response-derived value without echoing it. The endpoint
      # controls every field it returns, so a hostile or broken server can
      # park a token in token_type or expires_in exactly as easily as in the
      # body — the same leak, one field deeper. Values are reported by
      # type/shape, except for a short allow-list of protocol constants that
      # carry no data.
      def describe_response_value(value, allow: [])
        return "null" if value.nil?
        return value.to_s if value == true || value == false
        return "a #{value.class}" if value.is_a?(Numeric)

        if value.is_a?(String)
          return value if allow.any? { |ok| value.casecmp?(ok) }

          return "a #{value.length}-character String"
        end

        "a #{value.class}"
      end

      # Body-free diagnostics: enough to tell a captive portal from an HTML
      # error page from an empty response, with no response content.
      def response_summary(response, raw)
        content_type = response["content-type"] if response.respond_to?(:[])
        "content-type=#{content_type ? content_type.split(';').first : 'unset'}, " \
          "#{raw.bytesize} bytes, body redacted"
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
