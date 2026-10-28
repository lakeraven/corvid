# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "ipaddr"
require "date"
require "time"
require "zlib"
require "bigdecimal"
require "openssl"
require "zlib"
require "corvid/adapters/base"
require "corvid/value_objects"

module Corvid
  module Adapters
    # Generic FHIR R4 adapter. Translates Corvid's adapter interface into
    # FHIR REST calls. Does not depend on any vendor-specific extensions
    # beyond the Lakeraven extension URLs documented below.
    #
    # For text storage (notes, rationale, etc.), this adapter raises
    # NotImplementedError — production deployments must wire a vault
    # implementation. Vendor-specific adapters in corvid-adapters can
    # override store_text/fetch_text/dereference to use a real backend.
    class FhirAdapter < Base
      # Raised when a configured token_source yields a blank/non-string token.
      class TokenSourceError < StandardError; end

      # Raised when credentials would be sent over a non-TLS connection.
      # Subclasses ArgumentError because the usual cause is a misconfigured
      # base_url, caught at construction.
      class InsecureTransportError < ArgumentError; end

      # Raised when a credentialed request targets a URL outside base_url's
      # origin and path. The bearer token is scoped to the configured FHIR
      # base; server-supplied URLs (search next links) must never carry it
      # anywhere else.
      class CredentialScopeError < InsecureTransportError; end

      attr_reader :base_url

      EXTENSION_BASE_URL = "https://lakeraven.com/fhir/StructureDefinition"

      # Canonical billing code systems. A Claim.item.productOrService may carry
      # several codings (e.g. a SNOMED clinical concept alongside the billed
      # CPT/HCPCS); pricing needs the CPT/HCPCS one, not whichever happens to be
      # first. Both the FHIR-standard HCPCS OID and the CMS Blue Button HCPCS
      # URL are recognized since servers vary.
      CPT_SYSTEM = "http://www.ama-assn.org/go/cpt"
      HCPCS_SYSTEMS = [
        "urn:oid:2.16.840.1.113883.6.285",
        "https://bluebutton.cms.gov/resources/codesystem/hcpcs"
      ].freeze
      BILLING_CODE_SYSTEMS = ([ CPT_SYSTEM ] + HCPCS_SYSTEMS).freeze

      # Standard FHIR ServiceRequest fields safe to update directly.
      UPDATABLE_SERVICE_REQUEST_FIELDS = %w[
        status priority reasonCode note category chs_approval_status
      ].freeze

      # Case-domain fields stored as FHIR extensions on ServiceRequest.
      EXTENSION_FIELDS = %w[
        committee_decision committee_date approved_amount reviewer_identifier
        rationale conditions attendees denial_reason appeal_instructions
        appeal_deadline defer_reason modification_note
      ].freeze

      # Known Condition.category systems. An in-scope code is kept. An
      # explicit other code from these systems skips the row. A missing,
      # nil, or blank code in a known system makes the page unknown, as
      # does no category or only an unknown system.
      CONDITION_CATEGORY_SYSTEM = "http://terminology.hl7.org/CodeSystem/condition-category"
      US_CORE_CONDITION_CATEGORY_SYSTEM = "http://hl7.org/fhir/us/core/CodeSystem/condition-category"
      KNOWN_CONDITION_CATEGORY_SYSTEMS = [
        CONDITION_CATEGORY_SYSTEM,
        US_CORE_CONDITION_CATEGORY_SYSTEM
      ].freeze
      US_CORE_CONDITION_CATEGORIES = %w[problem-list-item encounter-diagnosis].freeze
      CONDITION_CLINICAL_SYSTEM = "http://terminology.hl7.org/CodeSystem/condition-clinical"
      # Full condition-clinical value set. An in-set code outside
      # INCLUDED_CLINICAL_STATUSES is dropped; a code outside this set makes
      # the page unknown.
      FHIR_CLINICAL_STATUSES = %w[active recurrence relapse inactive remission resolved].freeze
      INCLUDED_CLINICAL_STATUSES = %w[active recurrence relapse resolved].freeze
      EXCLUDED_VERIFICATION_STATUSES = %w[refuted entered-in-error].freeze
      # FHIR R4 medicationrequest-status. Missing or any other value is unknown.
      MEDICATION_REQUEST_STATUSES = %w[
        active on-hold cancelled completed entered-in-error stopped draft unknown
      ].freeze
      BLOCKING_OUTCOME_SEVERITIES = %w[error fatal].freeze
      # Plain-ASCII FHIR code token: printable ASCII runs separated by one
      # space. No padding, no empty string, and no character outside [!-~].
      # An OperationOutcome issue.code that is missing or is not this
      # token is unknown. Do not normalize or guess.
      FHIR_CODE_TOKEN = /\A[!-~]+(?: [!-~]+)*\z/
      # These tokens make the page unknown at any severity. Comparison is
      # code.downcase of a FHIR_CODE_TOKEN, with no whitespace or format
      # stripping. Other tokens still follow BLOCKING_OUTCOME_SEVERITIES.
      UNTRUSTED_OUTCOME_CODES = %w[
        suppressed incomplete too-costly timeout throttled too-long exception
      ].freeze
      # FHIR R4 dateTime grammar (anchored). Year and year-month are valid
      # partials and carry no day. Do not use Date.parse — it accepts prose.
      FHIR_YEAR = "(?:[0-9](?:[0-9](?:[0-9][1-9]|[1-9]0)|[1-9]00)|[1-9]000)"
      FHIR_MONTH = "(?:0[1-9]|1[0-2])"
      FHIR_DAY = "(?:0[1-9]|[1-2][0-9]|3[0-1])"
      FHIR_TIME = "T(?:[01][0-9]|2[0-3]):[0-5][0-9]:(?:[0-5][0-9]|60)" \
                  "(?:\\.[0-9]+)?(?:Z|[+-](?:(?:0[0-9]|1[0-3]):[0-5][0-9]|14:00))"
      FHIR_DATETIME = /
        \A
        (?<year>#{FHIR_YEAR})
        (?:-(?<month>#{FHIR_MONTH})(?:-(?<day>#{FHIR_DAY})(?:#{FHIR_TIME})?)?)?
        \z
      /x
      # FHIR R4 id. Checked before a Medication read so a bad id is not requested.
      FHIR_ID = /\A[A-Za-z0-9\-\.]{1,64}\z/

      # Maps Corvid resource types to FHIR Coverage.type codes (HL7 v3 ActCode).
      # Real servers vary; align with deployment ValueSet.

      # A search that cannot be trusted is unknown (nil), never a partial list.
      # ArgumentError covers Date::Error while mapping an unparseable date.
      # Header, protocol, and zlib faults are unknown too — they are not
      # subclasses of one another on Ruby 4.
      CLINICAL_READ_ERRORS = [
        Timeout::Error,
        SocketError,
        SystemCallError,
        OpenSSL::SSL::SSLError,
        IOError,
        Net::ProtocolError,
        Net::HTTPBadResponse,
        Net::HTTPHeaderSyntaxError,
        Zlib::Error,
        EncodingError,
        ArgumentError,
        JSON::ParserError
      ].freeze

      COVERAGE_TYPE_MAP = {
        "medicare_a"        => "MCRSC",
        "medicare_b"        => "MCRSC",
        "medicare_d"        => "MCRSC",
        "medicaid"          => "MCDSC",
        "va_benefits"       => "VET",
        "private_insurance" => "EHCPOL",
        "workers_comp"      => "WCPOL",
        "auto_insurance"    => "AUTOPOL",
        "liability_coverage" => "EHCPOL",
        "state_program"     => "SUBSIDIZ",
        "tribal_program"    => "TRIB",
        "charity_care"      => "CHAR"
      }.freeze

      DEFAULT_OPEN_TIMEOUT = 10
      DEFAULT_READ_TIMEOUT = 30
      # A Coverage search that reads this many Bundle pages is unknown,
      # including when the last page has no next link. A shorter chain
      # that ends is kept. Other searches use MAX_SEARCH_PAGES and may
      # use every page when the chain ends.
      MAX_COVERAGE_PAGES = 50
      # Coverage.kind. Absent and exact "insurance" stay on the allowlist.
      # Exact "self-pay" and "other" are not insurance, so the row is
      # dropped. Any other present value is unknown.
      COVERAGE_INSURANCE_KIND = "insurance"
      COVERAGE_EXCLUDED_KINDS = %w[self-pay other].freeze

      # Strict Coverage.period grammar. Anchored, and applied before any
      # Date or Time parse. Date.parse is never used on these bounds.
      COVERAGE_YEAR_RE = /\A\d{4}\z/
      COVERAGE_MONTH_RE = /\A\d{4}-\d{2}\z/
      COVERAGE_DATE_RE = /\A\d{4}-\d{2}-\d{2}\z/
      COVERAGE_DATETIME_RE =
        /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/
      # Coverage.status. Any other value fails the search closed.
      COVERAGE_STATUSES = %w[active cancelled draft entered-in-error].freeze
      # Exact OperationOutcome.issue.severity on a Coverage search. Any
      # other value, including a different case, fails the search.
      COVERAGE_OUTCOME_SEVERITIES = %w[fatal error warning information].freeze
      # Code "pay" is self-pay with either system below, or when the
      # coding has no system (issue #607 adds the STU3 system).
      COVERAGE_SELF_PAY_CODE = "pay"
      COVERAGE_SELFPAY_SYSTEM = "http://terminology.hl7.org/CodeSystem/coverage-selfpay"
      # STU3 Coverage self-pay code system (issue #607).
      COVERAGE_STU3_SELFPAY_SYSTEM = "http://hl7.org/fhir/coverage-selfpay"
      COVERAGE_PAY_SELF_PAY_SYSTEMS = [
        COVERAGE_SELFPAY_SYSTEM,
        COVERAGE_STU3_SELFPAY_SYSTEM
      ].freeze
      # X12 claim filing indicator (issue #607). On this system, code
      # "09", "9", or Integer 9 is self-pay. With no system, only "09".
      COVERAGE_X12_SELF_PAY_CODE = "09"
      COVERAGE_X12_SELF_PAY_SHORT_CODE = "9"
      COVERAGE_X12_SELF_PAY_INTEGER = 9
      COVERAGE_X12_CLAIM_FILING_INDICATOR_SYSTEM =
        "https://x12.org/codes/claim-filing-indicator-codes"
      # type.text is self-pay when Coverage.type has no coding and the
      # text, downcased with whitespace and hyphens removed, equals this
      # value (issue #607).
      COVERAGE_SELF_PAY_TEXT = "selfpay"
      # PHDSC Source of Payment Typology (issue #607). On any system
      # below, a coding is insurance only when its code is digits whose
      # first digit is in COVERAGE_SOP_INSURER_FIRST_DIGITS. A first digit
      # of 3 (IHS/Tribe incl. PRC), 8 (no payment), or 9 (miscellaneous),
      # or a non-digit code, is not insurance. Any such coding excludes
      # the Coverage even when another coding is an insurer code.
      # https://nahdo.org/sopt is the HL7 THO canonical URL of the same
      # typology.
      COVERAGE_SOP_SYSTEM = "urn:oid:2.16.840.1.113883.3.221.5"
      COVERAGE_SOP_BARE_OID = "2.16.840.1.113883.3.221.5"
      COVERAGE_SOP_NAHDO_SYSTEM = "https://nahdo.org/sopt"
      COVERAGE_SOP_SYSTEMS = [
        COVERAGE_SOP_SYSTEM,
        COVERAGE_SOP_BARE_OID,
        COVERAGE_SOP_NAHDO_SYSTEM
      ].freeze
      COVERAGE_SOP_INSURER_FIRST_DIGITS = "124567"
      # Digits whose first digit is an insurer family (issue #607).
      COVERAGE_SOP_INSURER_CODE_RE =
        /\A[#{COVERAGE_SOP_INSURER_FIRST_DIGITS}]\d*\z/
      COVERAGE_REFERENCE_ID_RE = %r{\A[^/?#]+\z}

      # The only names accepted as loopback. RFC 6761 reserves "localhost"
      # and ".localhost" and requires resolvers to keep them on the loopback
      # interface; every OTHER name — "ip6-localhost" and friends — is an
      # ordinary DNS lookup that a search domain or a hostile resolver can
      # point off-box, which would put a bearer token on the network. Literal
      # addresses are checked numerically via IPAddr#loopback?, not by name.
      LOOPBACK_NAME = "localhost"
      LOOPBACK_NAME_SUFFIX = ".localhost"

      # One search that still has a next page after this many Bundles is
      # undetermined. Callers never see a partial result.
      MAX_SEARCH_PAGES = 100

      # Next URL that aborts the search and is never requested.
      SEARCH_REJECTED = :rejected
      private_constant :SEARCH_REJECTED

      def initialize(base_url:, bearer_token: nil, token_source: nil, headers: {},
                     open_timeout: DEFAULT_OPEN_TIMEOUT,
                     read_timeout: DEFAULT_READ_TIMEOUT,
                     proxy_uri: nil,
                     ca_file: nil,
                     ca_path: nil,
                     allow_insecure_http: false)
        if token_source && !token_source.respond_to?(:call)
          raise ArgumentError,
                "token_source must be callable (respond to #call), " \
                "got #{token_source.class}"
        end
        if bearer_token && !(bearer_token.is_a?(String) && !bearer_token.strip.empty?)
          raise ArgumentError,
                "bearer_token must be a non-blank string when given, " \
                "got #{describe_token(bearer_token)}"
        end

        # Frozen: the reader hands this string to callers, and the transport
        # check reads it again per request. An unfrozen base_url could be
        # mutated to http:// after the construction-time check passed.
        @base_url = base_url.chomp("/").freeze
        @bearer_token = bearer_token
        # Off by default: an Authorization header on a cleartext connection
        # puts a live bearer token on the wire. The opt-out is honored only
        # for loopback hosts, and only for a literal boolean — see
        # #strict_boolean!.
        @allow_insecure_http = strict_boolean!(allow_insecure_http, :allow_insecure_http)
        # A callable resolved per request — e.g. a
        # Corvid::Auth::BackendServicesClient — so each call carries a
        # freshly-refreshed token. Takes precedence over the static
        # bearer_token when both are given.
        @token_source = token_source
        @default_headers = {
          "Accept" => "application/fhir+json",
          "Content-Type" => "application/fhir+json"
        }.merge(headers)
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @proxy_uri = build_proxy_uri(proxy_uri)
        @ca_file = ca_file
        @ca_path = ca_path

        # Fail at configuration time, not on the first PHI request, when
        # credentials are paired with a non-TLS base_url. A caller-supplied
        # Authorization header counts: it is a credential the same as a
        # configured one, and it is the request-level check below that is
        # authoritative either way.
        #
        # A path with no real segment is rejected with or without
        # credentials. Tokens and next links are scoped to this path; an
        # empty path, a dot segment, a path parameter, or an encoded
        # separator would cover or escape the host. An unparseable
        # base_url fails closed here as well. TLS, host, and credential
        # checks below still run for a path-qualified base.
        require_path_qualified_base_url!(@base_url)
        if bearer_token || token_source || preset_authorization_header?
          require_secure_transport!(@base_url)
        end
      end

      # The default #inspect renders every ivar: the static bearer_token, a
      # preset Authorization header, and the token_source (whose own inspect
      # may hold a cached token). Only the base URL and the auth mode show.
      def inspect
        auth = if @token_source then "token_source"
        elsif @bearer_token then "bearer_token"
        elsif preset_authorization_header? then "authorization_header"
        else "none"
        end
        "#<#{self.class.name} base_url=#{@base_url.inspect} auth=#{auth}>"
      end

      # True when the caller wired an Authorization header in directly.
      # Matched case-insensitively: HTTP header names are case-insensitive
      # and Net::HTTP will send "authorization" just as happily.
      def preset_authorization_header?
        @default_headers.any? { |name, _| name.to_s.casecmp?("authorization") }
      end
      private :preset_authorization_header?

      # A config-driven opt-out must not be defeated by Ruby truthiness: the
      # STRING "false" is truthy, so `allow_insecure_http: ENV["X"]` would
      # silently DISABLE the protection for every value of X except nil —
      # including "false", "0" and "". Only a literal boolean is accepted;
      # anything else is a configuration error rather than a quiet grant.
      def strict_boolean!(value, name)
        return value if value == true || value == false

        raise ArgumentError,
              "#{name} must be true or false (a literal boolean), got #{value.class}. " \
              "Parse environment variables explicitly — the string \"false\" is " \
              "truthy in Ruby and would silently disable this check."
      end
      private :strict_boolean!

      def build_proxy_uri(raw)
        return nil if raw.nil?

        uri = URI.parse(raw)
        # Net::HTTP::Proxy does not perform TLS to the proxy itself; an
        # "https://" proxy URI would silently be treated as HTTP-on-443
        # and fail against a real TLS-wrapped HTTPS proxy. Reject loudly
        # so the operator can re-route through stunnel or similar.
        unless uri.scheme == "http"
          raise ArgumentError,
                "FhirAdapter proxy_uri must use the http:// scheme " \
                "(got #{uri.scheme.inspect}). HTTPS proxies are not " \
                "supported by Net::HTTP::Proxy; tunnel through stunnel " \
                "or an outbound HTTP CONNECT proxy instead."
        end
        uri
      end
      private :build_proxy_uri

      # ----------------------------------------------------------------------
      # Patient
      # ----------------------------------------------------------------------

      def find_patient(patient_identifier)
        resource = fhir_read("Patient", patient_identifier)
        return nil unless resource

        Corvid::PatientReference.new(
          identifier: resource["id"],
          display_name: format_human_name(resource.dig("name", 0)),
          dob: parse_date(resource["birthDate"]),
          sex: resource["gender"],
          ssn_last4: extract_ssn_last4(resource)
        )
      end

      # nil when the search did not answer; [] when it answered with no matches.
      def search_patients(query)
        references_from_search("Patient", { name: query }) { |resource| build_patient_reference(resource) }
      end

      # ----------------------------------------------------------------------
      # Practitioner
      # ----------------------------------------------------------------------

      def find_practitioner(practitioner_identifier)
        resource = fhir_read("Practitioner", practitioner_identifier)
        return nil unless resource

        build_practitioner_reference(resource)
      end

      # nil when the search did not answer; [] when it answered with no matches.
      def search_practitioners(query)
        references_from_search("Practitioner", { name: query }) { |resource| build_practitioner_reference(resource) }
      end

      # ----------------------------------------------------------------------
      # Referral / ServiceRequest
      # ----------------------------------------------------------------------

      def find_referral(referral_identifier)
        resource = fhir_read("ServiceRequest", referral_identifier)
        return nil unless resource

        build_referral_reference(resource)
      end

      def create_referral(patient_identifier, params)
        body = {
          resourceType: "ServiceRequest",
          status: "draft",
          intent: "order",
          subject: { reference: "Patient/#{patient_identifier}" },
          reasonCode: params[:reason] ? [ { text: params[:reason] } ] : []
        }
        result = fhir_create("ServiceRequest", body)
        result&.dig("id")
      end

      def update_referral(referral_identifier, params)
        existing = fhir_read("ServiceRequest", referral_identifier)
        return false unless existing

        string_params = params.transform_keys(&:to_s)

        # Standard fields merged directly
        existing.merge!(string_params.slice(*UPDATABLE_SERVICE_REQUEST_FIELDS))

        # Case-domain fields stored as FHIR extensions
        ext_params = string_params.slice(*EXTENSION_FIELDS)
        if ext_params.any?
          existing["extension"] ||= []
          ext_params.each do |key, value|
            url = "#{EXTENSION_BASE_URL}/#{key.tr('_', '-')}"
            existing["extension"].reject! { |e| e["url"] == url }
            existing["extension"] << build_extension(url, value)
          end
        end

        fhir_update("ServiceRequest", referral_identifier, existing)
      end

      # nil when the patient identifier is blank or the search did not
      # answer; [] when the search answered with no matches.
      def list_referrals(patient_identifier)
        return nil if blank_patient_identifier?(patient_identifier)

        references_from_search("ServiceRequest", { patient: patient_identifier }) do |resource|
          build_referral_reference(resource)
        end
      end

      # ----------------------------------------------------------------------
      # Claims — purchased/referred-care billed line items
      #
      # Reads stock FHIR R4 `Claim` resources (`Claim?patient=<id>`) and
      # flattens each `Claim.item` into a Corvid::ClaimLineReference. Uses
      # only standard R4 elements — patient, provider, item.productOrService
      # (CPT/HCPCS coding), item.servicedDate/servicedPeriod, item.net — so
      # any conformant FHIR server (regardless of source EHR) maps the same
      # way. No vendor-specific extensions. nil when the patient identifier
      # is blank or the search did not answer; [] when it answered with no
      # matches. In memory only — never persist or log (ADR 0003).
      # ----------------------------------------------------------------------

      def list_claims(patient_identifier)
        return nil if blank_patient_identifier?(patient_identifier)

        claims = list_search_resources("Claim", { patient: patient_identifier })
        return nil if claims.nil?

        claim_lines_from(claims)
      end

      # One Condition search page only. A Bundle.link relation "next" is
      # unknown. Array of ConditionReference, or nil when the page is
      # unknown. [] means none. Bundle.type must be searchset. A positive
      # total counts only with a match-mode Condition entry. Requires a
      # code, and a category from the HL7 or US Core condition-category
      # system whose code is in scope. A missing, nil, or blank code in
      # that system is unknown; an explicit out-of-scope code is excluded.
      # Clinical status must be condition-clinical or system-less, the
      # codings must agree, and the value must be active, recurrence,
      # relapse, or resolved.
      # Refuted and entered-in-error are excluded in any system. The same
      # codes given only as verificationStatus text, stripped and
      # case-insensitive, are excluded too. Entered-in-error is dropped
      # even when clinical status is unusable. An OperationOutcome issue
      # whose code is missing or is not a plain-ASCII FHIR code token is
      # unknown at any severity, including a non-String. Never raises.
      # In memory only — never persisted or logged (ADR 0003).
      def get_conditions(patient_identifier)
        clinical_search("Condition", patient_identifier) do |bundle|
          map_condition_entries(bundle, patient_identifier)
        end
      rescue StandardError
        nil
      end

      # One MedicationRequest search page only. A Bundle.link relation
      # "next" is unknown. Bundle.type must be searchset. A positive total
      # counts only with a match-mode MedicationRequest entry. Resolves
      # contained, bundle-included, or same-server Medication references. A
      # bundled Medication is used only when fullUrl is absent,
      # Medication/<id>, or base_url/Medication/<id>. Status must be an R4
      # medicationrequest-status code; missing or any other status makes
      # the page unknown. Subject is checked before exclusions, so another
      # patient's request is unknown even when it would be excluded.
      # Boolean doNotPerform true and entered-in-error are excluded.
      # Boolean false or an absent doNotPerform is kept. Any other
      # doNotPerform value makes the page unknown. Code is the first
      # coding with a non-empty code; display falls back to that coding's
      # display, then text. No such coding and no text is unknown. Invalid
      # Medication ids are not requested. An OperationOutcome issue whose
      # code is missing or is not a plain-ASCII FHIR code token is
      # unknown at any severity, including a non-String. Never raises.
      # Array of MedicationReference, or nil when unknown. In memory only —
      # never persisted or logged (ADR 0003).
      def get_medications(patient_identifier)
        clinical_search("MedicationRequest", patient_identifier) do |bundle|
          map_medication_entries(bundle, patient_identifier)
        end
      rescue StandardError
        nil
      end

      # ----------------------------------------------------------------------
      # Vault: text storage
      #
      # FHIR R4 has no native "encrypted blob storage" concept. Production
      # deployments must wire a real vault (e.g. via DocumentReference with
      # a private content URL, or a separate vault service). The default
      # implementation raises so misconfigurations fail loudly.
      # ----------------------------------------------------------------------

      def store_text(case_token:, kind:, text:)
        raise NotImplementedError, "FhirAdapter#store_text requires a vault implementation"
      end

      def fetch_text(text_token)
        raise NotImplementedError, "FhirAdapter#fetch_text requires a vault implementation"
      end

      def dereference(token)
        raise NotImplementedError, "FhirAdapter#dereference requires a vault implementation"
      end

      def dereference_many(tokens)
        raise NotImplementedError, "FhirAdapter#dereference_many requires a vault implementation"
      end

      # ----------------------------------------------------------------------
      # Site params (FHIR Organization metadata or none)
      # ----------------------------------------------------------------------

      def get_site_params
        {}
      end

      # ----------------------------------------------------------------------
      # Care team
      # ----------------------------------------------------------------------

      # nil when the patient identifier is blank or the search did not
      # answer; [] when the search answered with no matches.
      def get_care_team(patient_identifier)
        return nil if blank_patient_identifier?(patient_identifier)

        teams = list_search_resources("CareTeam", { patient: patient_identifier })
        return nil if teams.nil?

        teams.flat_map { |team| care_team_members(team) }
      end

      # ----------------------------------------------------------------------
      # Coverages
      #
      # GET Coverage?beneficiary=Patient/<id>. A nil, empty, or
      # whitespace-only patient identifier is nil and makes no request.
      # Bundle.type must equal "searchset" or the search is nil. Pages
      # come from #collect_search_pages: one next-link walker, the same
      # origin and path checks, and the same repeat detection as
      # #fhir_search. Each page is loaded through #fetch_bundle_page.
      # The Coverage cap is MAX_COVERAGE_PAGES. A chain
      # that long is unknown. A relation containing a Unicode format
      # character (general category Cf, such as U+200B or U+FEFF) is
      # unknown and is not requested.
      #
      # Every Coverage must name this patient. beneficiary.reference is
      # accepted only as "Patient/<id>" or exactly
      # "#{base_url}/Patient/<id>". Any other reference, including an
      # absolute URL on another server, makes the whole result nil.
      #
      # Insurance is an allowlist. A Coverage is included only when every
      # payor is a Hash whose reference is "Organization/<id>" or exactly
      # "#{base_url}/Organization/<id>", and there is at least one payor.
      # No type.coding, in any position, may be self-pay or a non-insurer
      # PHDSC code (issue #607). Self-pay is code "pay" with system
      # http://terminology.hl7.org/CodeSystem/coverage-selfpay, system
      # http://hl7.org/fhir/coverage-selfpay (STU3), or no system; or
      # code "09", "9", or Integer 9 with system
      # https://x12.org/codes/claim-filing-indicator-codes; or code "09"
      # with no system. On PHDSC Source of Payment Typology system
      # urn:oid:2.16.840.1.113883.3.221.5, bare OID
      # 2.16.840.1.113883.3.221.5, or https://nahdo.org/sopt, a coding is
      # insurance only when its code is digits whose first digit is 1, 2,
      # 4, 5, 6, or 7. A first digit of 3 (IHS/Tribe incl. PRC), 8 (no
      # payment), or 9 (miscellaneous), or a non-digit code, is not
      # insurance; any such coding excludes the Coverage even when another
      # coding is an insurer code. Codes in other systems keep the prior
      # rules. type.text, downcased with whitespace and hyphens removed,
      # equal to "selfpay" is self-pay when there is no coding. kind
      # absent or exactly "insurance" continues the allowlist. Exact
      # "self-pay" or "other" excludes the row. Any other present kind
      # is nil. Coverages excluded by this allowlist still count toward
      # the total check.
      #
      # The array is active coverages whose period covers now. A missing
      # start or end is an open bound. A present bound must match strict
      # FHIR grammar before any calendar parse (anchored patterns, never
      # Date.parse) or the whole result is nil: YYYY, YYYY-MM, YYYY-MM-DD,
      # or YYYY-MM-DDThh:mm:ss(.fraction)?(Z|[+-]hh:mm). Year is Jan 1
      # (start) or Dec 31 (end). Month is the first or last day. A date is
      # that date. Those are compared with Date.current and stored on
      # coverage_start / coverage_end. A dateTime is an instant compared
      # with Time.current; the stored value is the UTC calendar date of
      # that instant. One parser feeds both the filter and the mapping.
      #
      # status must be active, cancelled, draft, or entered-in-error;
      # any other value, including a missing status, is nil. A Coverage
      # with "period" present but not an object is nil. A malformed shape
      # (type, payor, beneficiary, class, or coding that is not the Hash,
      # Array, or String that element requires) is nil and does not raise.
      # payor[0].display, subscriberId, and any type.coding code, when
      # present but not a String, make the search nil. Integer 9 on the
      # X12 claim-filing-indicator system remains self-pay.
      # A Coverage entry is counted only when it has no search, no mode, or
      # mode "match", on every page, before the active and insurance
      # filters. Any other search on a Coverage entry is malformed and the
      # read is unknown: search present and not a Hash, a mode present and
      # not a String, a mode that is not a FHIR search mode, or mode
      # "include" or "outcome". A malformed search on any entry, on any
      # page, is unknown. When a page includes total, it must be an
      # Integer >= 0 and equal to the first page's total; a later
      # page may omit total. The first page's total must equal that count,
      # or the result is nil. An OperationOutcome entry is nil when issue
      # is missing, not an Array, empty, contains a non-Hash, or has a
      # severity other than exactly "fatal", "error", "warning", or
      # "information". An issue code that is missing or is not a
      # plain-ASCII FHIR code token (FHIR_CODE_TOKEN) is nil: a missing
      # key, JSON null, a non-String, invalid encoding, look-alike
      # characters, padding, or "". Nothing is stripped or rewritten.
      # UNTRUSTED_OUTCOME_CODES are nil at any severity when that token
      # matches one of them case-insensitively (code.downcase).
      # "error" and "fatal" still block. A well-formed warning or
      # information issue with another code token is ignored. A
      # resourceType equal to "OperationOutcome" case-insensitively or
      # after stripping, but not exactly, is nil. A page with no entry and total nil
      # or 0 is empty. A first page with no entry, a
      # positive total, and no next link is nil via the count check. A
      # string anywhere in the bundle that fails valid_encoding? is nil
      # and does not raise.
      # An entry that is not a Hash, an entry without a Hash resource, or
      # a resource without a String resourceType is nil. A resourceType
      # equal to "Coverage" case-insensitively but not exactly is nil.
      # An entry whose resourceType is neither Coverage nor
      # OperationOutcome is nil unless search.mode is exactly "include"
      # (that entry is skipped). Each Coverage id is tracked across all
      # pages. A Coverage without a non-empty String id, or a repeated
      # id, is nil.
      # plan_name is the class entry typed "plan": its name, otherwise
      # its value.
      #
      # An Array means the search finished ([] when nothing matched). nil
      # means unknown — a non-2xx page, bad JSON, a non-Bundle body, a
      # Bundle.type other than "searchset", a malformed link or entry, a
      # malformed entry search, a missing or duplicate Coverage id, an
      # untrusted beneficiary or
      # period, a malformed Coverage, a status outside the FHIR set, a
      # total that is not an Integer >= 0, differs from the first page,
      # or does not match the Coverage count, invalid encoding, an
      # untrusted or inexact OperationOutcome, an empty issue array, a
      # missing issue code or one that is not a FHIR code token, an
      # unexpected resource without search.mode "include", a blank patient
      # identifier, a non-String
      # payor display, subscriberId, or type code, a malformed kind,
      # an off-origin / cyclic / over-limit next link, a next relation
      # that matches only after removing [[:space:]] or case-folding,
      # or a relation that contains a format character,
      # or a transport or URI error
      # (Timeout::Error, including Net::ReadTimeout and Net::OpenTimeout,
      # SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError,
      # Net::ProtocolError, Net::HTTPBadResponse,
      # Net::HTTPHeaderSyntaxError, Zlib::Error, URI::Error, ArgumentError).
      # A non-http(s) base_url returns nil. Callers fail closed; a partial
      # page list is never returned.
      # ----------------------------------------------------------------------

      def get_coverages(patient_identifier)
        return nil if patient_identifier.blank?

        query = URI.encode_www_form(beneficiary: "Patient/#{patient_identifier}")
        pages = collect_search_pages("#{@base_url}/Coverage?#{query}", **page_cap_for("Coverage"))
        coverage_rows_from_pages(pages, patient_identifier) if pages
      rescue Timeout::Error, SocketError, SystemCallError,
             OpenSSL::SSL::SSLError, IOError, Net::ProtocolError,
             Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Zlib::Error,
             URI::Error, ArgumentError
        nil
      end

      # ----------------------------------------------------------------------
      # Eligibility
      # ----------------------------------------------------------------------

      def verify_eligibility(patient_identifier, resource_type)
        bundle = fhir_search("Coverage", beneficiary: "Patient/#{patient_identifier}")
        coverage = coverage_for_resource_type(extract_entries(bundle), resource_type)
        return nil unless coverage

        {
          eligible: coverage["status"] == "active",
          payer_name: coverage.dig("payor", 0, "display"),
          policy_number: coverage["subscriberId"],
          coverage_start: parse_period_date(coverage.dig("period", "start"), :start),
          coverage_end: parse_period_date(coverage.dig("period", "end"), :end)
        }
      end

      # ----------------------------------------------------------------------
      # Enrollment verification — FHIR R4 / US Core have no native tribal
      # enrollment concept, so this reads Lakeraven's tribal-enrollment
      # extension on Patient (see TRIBAL_ENROLLMENT_EXTENSION_URL below).
      # A failed Patient read (including a transport failure), or a Patient
      # with no tribal-enrollment extension, is unknown enrollment: enrolled is nil and confidence
      # is :unavailable. That is not a recorded denial.
      # ----------------------------------------------------------------------

      TRIBAL_ENROLLMENT_EXTENSION_URL = "#{EXTENSION_BASE_URL}/tribal-enrollment"
      RESIDENCY_EXTENSION_URL = "#{EXTENSION_BASE_URL}/residency"
      US_CORE_BIRTHPLACE_URL = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-birthplace"

      def verify_tribal_enrollment(patient_identifier)
        patient = verification_patient_read(patient_identifier)
        return tribal_enrollment_unavailable unless patient

        ext = find_extension(patient, TRIBAL_ENROLLMENT_EXTENSION_URL)
        return tribal_enrollment_unavailable unless ext

        tribal_enrollment_from(ext)
      end

      def verify_identity_documents(patient_identifier)
        empty = { ssn_present: false, dob_present: false, birthplace_present: false, verified_at: Time.current }

        patient = verification_patient_read(patient_identifier)
        return empty unless patient

        {
          ssn_present: extract_ssn_last4(patient).present?,
          dob_present: patient["birthDate"].present?,
          birthplace_present: !!find_extension(patient, US_CORE_BIRTHPLACE_URL),
          verified_at: Time.current
        }
      end

      def verify_residency(patient_identifier)
        unavailable = { on_reservation: false, address: nil, service_area: nil, verified_at: Time.current }

        patient = verification_patient_read(patient_identifier)
        return unavailable unless patient

        ext = find_extension(patient, RESIDENCY_EXTENSION_URL)
        return unavailable unless ext

        {
          on_reservation: sub_extension_value(ext, "onReservation") == true,
          address: format_address(patient.dig("address", 0)),
          service_area: sub_extension_value(ext, "serviceArea"),
          verified_at: Time.current
        }
      end

      # ----------------------------------------------------------------------
      # Billing / EDI — FHIR has no native clearinghouse concept.
      # Defaults to "not available" so callers degrade gracefully.
      # Vendor adapters (Clearinghouse, etc.) override with real EDI integration.
      # ----------------------------------------------------------------------

      def submit_claim(_claim_data)
        { claim_identifier: nil, status: "unsupported" }
      end

      def check_claim_status(claim_identifier)
        return nil if claim_identifier.nil? || claim_identifier.to_s.empty?
        return nil unless fhir_read("Claim", claim_identifier)

        { status: "unsupported", paid_amount: nil, adjustment_amount: nil, paid_date: nil }
      end

      def fetch_remittances(date_range: nil)
        []
      end

      def check_eligibility_detailed(_patient_identifier, _payer_id)
        { eligible: false, payer_name: nil, plan_name: nil }
      end

      def search_payers(_query)
        []
      end

      def process_payment(amount_cents:, patient_identifier:, description:)
        { payment_identifier: nil, status: "unsupported" }
      end

      def refund_payment(_payment_identifier)
        { refund_identifier: nil, status: "unsupported" }
      end

      # ----------------------------------------------------------------------
      # Budget — FHIR has no native budget concept. Reads degrade to an
      # empty summary; the encumbrance WRITE must not fabricate success
      # (same posture as #store_text): a vendor adapter that can actually
      # reserve funds overrides #create_obligation.
      # ----------------------------------------------------------------------

      def get_budget_summary(facility_identifier: nil)
        {}
      end

      def create_obligation(_referral_identifier, _amount, _params = {})
        raise NotImplementedError,
          "FhirAdapter#create_obligation requires a budget backend — " \
          "stock FHIR cannot encumber CHS funds, so reporting success here " \
          "would record an obligation that was never made"
      end

      # Stock FHIR cannot make obligations, so it has none to read. These
      # raise rather than answer nil / [] so a lookup is never mistaken for
      # "no obligation" (same posture as #create_obligation).
      def get_obligation(_obligation_id)
        raise NotImplementedError, "FhirAdapter#get_obligation requires a budget backend"
      end

      def get_obligation_by_referral(_referral_identifier)
        raise NotImplementedError, "FhirAdapter#get_obligation_by_referral requires a budget backend"
      end

      def get_payments(obligation_id:)
        raise NotImplementedError, "FhirAdapter#get_payments requires a budget backend"
      end

      private

      # FHIR REST primitives ------------------------------------------------

      def fhir_read(resource_type, id)
        return nil if unreadable_medication_id?(resource_type, id)

        response = http_get("#{@base_url}/#{resource_type}/#{id}")
        parse_success_json(response)
      end

      # Patient read for the verification primitives. A transport or parse
      # fault (connection refused, timeout, TLS, EOF, protocol) is an
      # unavailable source — nil, same as a failed read — never an exception
      # that would stop a fail-closed decision from being recorded.
      def verification_patient_read(patient_identifier)
        fhir_read("Patient", patient_identifier)
      rescue *CLINICAL_READ_ERRORS
        nil
      end

      # Returns one Bundle whose `entry` array is every page, in order.
      # Follows `link` entries with relation exactly "next", resolving each
      # URL with URI.join against the current page. Fail closed: returns nil
      # (never a partial Bundle) when any page is non-2xx, invalid JSON, an
      # empty or nil body, a String body that is not valid_encoding?, or not
      # a Bundle Hash; when `entry` is present and not an Array (absent or
      # null is an empty page); when `link` is present and not an Array;
      # when a link row is not a Hash, or its relation is not a String
      # (an Array relation included); when a relation or url String is not
      # valid_encoding?; when a relation contains a Unicode format
      # character (category Cf); when a relation equals "next" only after
      # removing [[:space:]] or case-folding (that URL is not requested);
      # when more than one exactly-"next" link is present (neither URL is
      # requested); when parsing, joining, or checking a next URL raises
      # URI::Error; when a next URL's scheme or port differs from
      # @base_url, or its host differs case-insensitively; when its path
      # does not start with @base_url's path at a segment boundary after
      # repeated percent-decoding and segment collapse; when that path
      # contains ";", a backslash, a control character, or an encoded
      # %2f/%5c/%3b/%25 (any case) before or after decoding, or a path
      # segment is "." or ".." (that URL is not requested); when a present
      # `total` is not a non-negative Integer, or differs from the count of
      # merged entries whose search.mode is "match" or absent, or whose
      # search value is not a Hash (an equal total is kept, an absent total
      # stays absent, and outcome and include entries are not counted); when
      # the same resourceType and id appear twice among those counted
      # entries (repeated include entries are allowed); when a later page's
      # Bundle.type differs from the first page's; when a next URL was
      # already visited; or when the chain exceeds the page cap. Coverage
      # uses MAX_COVERAGE_PAGES and is unknown when that many pages were
      # read. Other types use MAX_SEARCH_PAGES and keep a chain that ends on
      # the last page.
      def fhir_search(resource_type, params = {})
        query = URI.encode_www_form(params)
        url = "#{@base_url}/#{resource_type}?#{query}"
        pages = collect_search_pages(url, **page_cap_for(resource_type))
        merge_search_pages(pages) if pages
      end

      def page_cap_for(resource_type)
        return { page_limit: MAX_SEARCH_PAGES } unless resource_type == "Coverage"

        { page_limit: MAX_COVERAGE_PAGES, at_limit: :unknown }
      end

      # 204 and an empty body are not a resource. Parsing nil raises, and
      # that message must not escape with a URL or payload.
      def parse_success_json(response)
        return nil unless response.is_a?(Net::HTTPSuccess)
        return nil if empty_response?(response)

        JSON.parse(response.body)
      end

      # at_limit :unknown discards a chain that filled page_limit, even
      # when the last Bundle has no next link. :allow keeps that chain.
      def collect_search_pages(url, page_limit: MAX_SEARCH_PAGES, at_limit: :allow)
        pages = []
        seen = {}

        while url && pages.size < page_limit && !seen[url]
          page = fetch_bundle_page(url)
          return unless page && acceptable_entries?(page) && same_bundle_type?(pages, page)

          seen[url] = true
          pages << page
          url = next_search_url(page, url)
          return if url == SEARCH_REJECTED
        end

        search_pages_result(pages, url, page_limit, at_limit)
      end

      # A nil url means the chain ended. A leftover url is a page cap or a
      # repeated next link, so pages already read are discarded.
      def search_pages_result(pages, url, page_limit, at_limit)
        return if url
        return if at_limit == :unknown && pages.size >= page_limit

        pages
      end

      # One Bundle page, or nil when it cannot be read. Subclasses override
      # this to replace HTTP. #collect_search_pages is the only caller.
      def fetch_bundle_page(url)
        response = http_get(url)
        return unless response.is_a?(Net::HTTPSuccess)

        parse_search_bundle(response.body)
      end

      def parse_search_bundle(body)
        return if !body.is_a?(String) || body.empty? || !body.valid_encoding?

        bundle = JSON.parse(body)
        bundle if bundle.is_a?(Hash) && bundle["resourceType"] == "Bundle"
      rescue JSON::ParserError, TypeError, ArgumentError, EncodingError
        nil
      end

      def next_search_url(page, current_url)
        href = next_link_href(page)
        return href if href.nil? || href == SEARCH_REJECTED
        return SEARCH_REJECTED if dot_segment_path?(href)

        resolved = resolve_search_url(current_url, href)
        same_origin_url?(resolved) ? resolved : SEARCH_REJECTED
      end

      def next_link_href(bundle)
        links = bundle_links(bundle)
        return SEARCH_REJECTED if links == SEARCH_REJECTED
        return SEARCH_REJECTED unless links.all? { |link| sound_link?(link) }

        next_links = links.select { |link| next_relation?(link) }
        return SEARCH_REJECTED if next_links.size > 1
        return if next_links.empty?

        strict_href(next_links.first["url"])
      end

      def sound_link?(link)
        return false unless link.is_a?(Hash)
        return false if invalid_link_encoding?(link)

        relation = link["relation"]
        relation.is_a?(String) && !format_relation?(relation) && !near_miss_next_relation?(relation)
      end

      def invalid_link_encoding?(link)
        return false unless link.is_a?(Hash)

        [ link["relation"], link["url"] ].any? { |value| value.is_a?(String) && !value.valid_encoding? }
      end

      # Format characters are invisible. They must not be stripped into "next".
      def format_relation?(relation)
        relation.match?(/\p{Cf}/)
      end

      # Equals "next" once every [[:space:]] character is removed and case
      # is folded, but is not the exact relation that is followed.
      def near_miss_next_relation?(relation)
        relation != "next" && relation.gsub(/[[:space:]]/, "").casecmp?("next")
      end

      def strict_href(href)
        href.is_a?(String) && href.valid_encoding? && !href.empty? ? href : SEARCH_REJECTED
      end

      def next_relation?(link)
        link.is_a?(Hash) && link["relation"] == "next"
      end

      def bundle_links(bundle)
        links = bundle["link"]
        return links if links.is_a?(Array)
        return [] if links.nil?

        SEARCH_REJECTED
      end

      def resolve_search_url(current_url, href)
        URI.join(current_url, href).to_s
      rescue URI::Error
        nil
      end

      def same_origin_url?(url)
        return false if url.nil?

        origin = URI.parse(@base_url)
        other = URI.parse(url)
        return false unless origin.scheme == other.scheme && origin.port == other.port
        return false unless origin.host.is_a?(String) && origin.host.casecmp?(other.host)

        path_under_base?(origin.path, other.path)
      rescue URI::Error
        false
      end

      def path_under_base?(base_path, other_path)
        root = collapsed_search_path(base_path.to_s)
        child = collapsed_search_path(other_path.to_s)
        return false unless root && child

        child == root || child.start_with?(root == "/" ? "/" : "#{root}/")
      end

      # Repeated decoding, then "." / ".." collapse. nil when the path is
      # not absolute after decoding, contains a control character or
      # backslash, or ".." would climb above the root. An empty path is
      # the host root.
      def collapsed_search_path(path)
        decoded = repeated_decode(path)
        return nil unless decoded.is_a?(String)
        return nil if decoded.match?(/[[:cntrl:]\\]/)
        return nil unless decoded.empty? || decoded.start_with?("/")

        collapse_search_segments(decoded)
      end

      def collapse_search_segments(decoded)
        segments = []
        decoded.split("/").each do |segment|
          next if segment.empty? || segment == "."
          return nil if segment == ".." && segments.empty?

          segment == ".." ? segments.pop : segments << segment
        end
        "/#{segments.join("/")}"
      end

      def repeated_decode(path)
        decoded = path
        5.times do
          nxt = URI.decode_uri_component(decoded)
          return nxt if nxt == decoded

          decoded = nxt
        end
        nil
      rescue ArgumentError
        nil
      end

      # "." and ".." segments are rejected before fetch, including those
      # that appear only after repeated percent-decoding. ";", a
      # backslash, a control character, encoded separators %2f/%5c, an
      # encoded ";" (%3b) and any double-encoded escape (%25), all in
      # any case, are rejected on the raw path and on the decoded path.
      # A gateway that decodes, strips path parameters and normalizes
      # dot segments could otherwise route the request outside the base.
      def dot_segment_path?(href)
        raw = URI.parse(href).path.to_s
        return true if forbidden_next_path?(raw)

        unsafe_decoded_path?(repeated_decode(raw))
      rescue URI::Error
        false
      end

      def unsafe_decoded_path?(decoded)
        return true unless decoded.is_a?(String)
        return true if forbidden_next_path?(decoded) || decoded.match?(/[[:cntrl:]\\]/)

        dot_segment?(decoded)
      end

      def dot_segment?(path)
        path.split("/").any? { |segment| segment == "." || segment == ".." }
      end

      def forbidden_next_path?(path)
        path.match?(/[;\\]|%2f|%5c|%3b|%25/i)
      end

      def merge_search_pages(pages)
        entries = pages.flat_map { |page| page_entries(page) }
        return if total_mismatch?(pages.first, entries)
        return if duplicate_match_entries?(entries)

        merged = pages.first.dup
        merged["entry"] = entries
        strip_next_links(merged)
        merged
      end

      def total_mismatch?(page, entries)
        return false unless page.key?("total")

        total = page["total"]
        return true unless total.is_a?(Integer) && total >= 0

        total != entries.count { |entry| search_match_entry?(entry) }
      end

      def duplicate_match_entries?(entries)
        keys = entries.filter_map { |entry| match_resource_key(entry) }
        keys.size != keys.uniq.size
      end

      # Counts for fhir_search total and duplicate checks. A non-Hash entry,
      # a non-Hash search, or a missing mode is a match. A Hash search counts
      # only when mode is absent or "match"; include, outcome, and any other
      # mode do not. List reads do not use this: a non-Hash search or an
      # unrecognized mode is unknown there.
      def search_match_entry?(entry)
        return true unless entry.is_a?(Hash)

        search = entry["search"]
        return true unless search.is_a?(Hash)

        mode = search["mode"]
        mode.nil? || mode == "match"
      end

      def match_resource_key(entry)
        return unless search_match_entry?(entry)
        return unless entry.is_a?(Hash)

        resource = entry["resource"]
        return unless resource.is_a?(Hash)

        type = resource["resourceType"]
        id = resource["id"]
        [ type, id ] unless type.nil? || id.nil?
      end

      # The first page may be any Bundle.type. Every later page must
      # declare that same type; a missing type is not the same as "searchset".
      def same_bundle_type?(pages, page)
        pages.empty? || page["type"] == pages.first["type"]
      end

      def acceptable_entries?(page)
        return true unless page.key?("entry")

        entry = page["entry"]
        entry.nil? || entry.is_a?(Array)
      end

      # Search pagination. Always an Array: a missing, null, or non-Array
      # entry is an empty page. A non-Array entry never reaches
      # merge_search_pages; acceptable_entries? rejects that page first.
      def page_entries(page)
        entries = page["entry"]
        entries.is_a?(Array) ? entries : []
      end

      def strip_next_links(bundle)
        links = bundle["link"]
        return unless links.is_a?(Array)

        bundle["link"] = links.reject { |link| next_relation?(link) }
      end

      def empty_response?(response)
        return true if response.code == "204"

        body = response.body
        body.nil? || body.empty?
      end

      def unreadable_medication_id?(resource_type, id)
        resource_type == "Medication" && !fhir_id?(id)
      end

      def fhir_id?(id)
        id.is_a?(String) && FHIR_ID.match?(id)
      end

      def fhir_create(resource_type, body)
        response = http_post("#{@base_url}/#{resource_type}", body.to_json)
        return nil unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPCreated)

        JSON.parse(response.body)
      end

      def fhir_update(resource_type, id, body)
        response = http_put("#{@base_url}/#{resource_type}/#{id}", body.to_json)
        response.is_a?(Net::HTTPSuccess)
      end

      # HTTP helpers --------------------------------------------------------

      def http_get(url)
        execute_http(:get, url)
      end

      def http_post(url, body)
        execute_http(:post, url, body)
      end

      def http_put(url, body)
        execute_http(:put, url, body)
      end

      def execute_http(method, url, body = nil)
        uri = URI.parse(url)
        request = case method
        when :get  then Net::HTTP::Get.new(uri)
        when :post then Net::HTTP::Post.new(uri).tap { |r| r.body = body }
        when :put  then Net::HTTP::Put.new(uri).tap { |r| r.body = body }
        end
        @default_headers.each { |k, v| request[k] = v }
        # Checked before the token source is consulted, so an out-of-scope
        # URL neither spends a grant nor receives a credential.
        require_credential_scope!(url) if credentialed?
        token = resolve_bearer_token
        request["Authorization"] = "Bearer #{token}" unless token.nil? || token.strip.empty?

        # Authoritative check, keyed on what the request ACTUALLY carries
        # rather than on what was configured: a caller-supplied
        # headers["Authorization"] is just as much a credential as a
        # resolved token, and base_url is not the only URL that reaches
        # here. Runs after every header is applied and before the socket.
        require_secure_transport!(url) if request["Authorization"]

        build_http(uri).request(request)
      end

      def credentialed?
        !@token_source.nil? || !@bearer_token.nil? || preset_authorization_header?
      end

      # The bearer token belongs to base_url alone: same scheme, host and
      # port, a path at or under the base path, no userinfo, and no dot
      # segment or encoded separator a gateway could normalize out of the
      # base. The message names neither the URL nor its host — both are
      # server-supplied for a next link, and a path carries record ids.
      def require_credential_scope!(url)
        uri = URI.parse(url.to_s)
        return if uri.userinfo.nil? && same_origin_url?(url.to_s) && !dot_segment_path?(url.to_s)

        raise CredentialScopeError,
              "FhirAdapter refuses to send credentials to a URL outside the " \
              "configured base_url origin and path"
      rescue URI::InvalidURIError
        raise CredentialScopeError, "FhirAdapter refuses to send credentials to an unparseable URL"
      end

      # Bearer tokens and followed search next links are scoped to
      # base_url's scheme, host, port, and path. A path with no real
      # segment is rejected whether or not credentials are present.
      # Empty or slash-only paths fail that check directly. "." and ".."
      # segments (including %2e/%2E), path parameters (";"), and encoded
      # separators (%2F/%5C) are the same rule dot_segment_path? already
      # applies to search next links: it percent-decodes %2e and calls
      # forbidden_next_path? on the raw and decoded path. A segment that
      # merely contains a dot (for example "fhir.v2") stays valid.
      # An unparseable URL — URI::InvalidURIError, or a string URI.parse
      # cannot handle — raises ArgumentError here with or without
      # credentials. The message does not echo the URL; parser errors quote it.
      def require_path_qualified_base_url!(url)
        uri = parse_base_url!(url)
        return unless uri.path.to_s.delete("/").empty? || dot_segment_path?(url.to_s)

        raise ArgumentError,
              "base_url must be path-qualified so bearer tokens and search " \
              "next links stay scoped to the FHIR base path, not the whole " \
              "host (for example https://fhir.vendor.example/r4)"
      end

      # Fail closed. URI::InvalidURIError is the usual parse failure;
      # some strings raise ArgumentError instead (a null byte, on a parser
      # that rejects it before the URI check). Either one becomes
      # ArgumentError. cause is cleared: the parser message quotes the URL,
      # and Ruby would otherwise attach it to the new exception.
      def parse_base_url!(url)
        URI.parse(url.to_s)
      rescue URI::InvalidURIError, ArgumentError
        raise ArgumentError,
              "base_url could not be parsed; FhirAdapter refuses an unparseable base URL",
              cause: nil
      end

      # Reject any URL that would carry an Authorization header over a
      # non-TLS connection. Requests with no Authorization header are
      # untouched, so genuinely unauthenticated on-prem and in-memory demo
      # use over plain http still works.
      #
      # The opt-out is deliberately narrow: it applies only when every hop
      # stays on the loopback interface, where traffic never reaches a
      # network. Setting it does NOT license cleartext credentials to a
      # remote host.
      def require_secure_transport!(url)
        uri = URI.parse(url.to_s)
        return if uri.scheme == "https"
        return if @allow_insecure_http && loopback_peer?(uri)

        # Host only, never the path — a FHIR path carries record identifiers.
        raise InsecureTransportError,
              "FhirAdapter refuses to send an Authorization header over " \
              "#{uri.scheme.inspect} (host #{uri.host.inspect}). Use https; " \
              "#{insecure_opt_out_detail(uri)}."
      rescue URI::InvalidURIError => e
        raise InsecureTransportError, "invalid FHIR base URL: #{e.message}"
      end

      # "Is this loopback?" is a question about the actual network peers,
      # not about the URL alone. A proxy is the host we really connect to,
      # and it then makes its own hop to the target — so a cleartext request
      # is confined to the machine only if BOTH ends are loopback. A remote
      # proxy in front of a localhost URL still puts the token on the wire.
      def loopback_peer?(uri)
        return false unless loopback_host?(uri.host)
        return false if @proxy_uri && !loopback_host?(@proxy_uri.host)

        true
      end

      def insecure_opt_out_detail(uri)
        return "pass allow_insecure_http: true for a loopback endpoint only" unless @allow_insecure_http

        if @proxy_uri && !loopback_host?(@proxy_uri.host) && loopback_host?(uri.host)
          "allow_insecure_http does not apply here: proxy_uri routes this " \
            "request through a non-loopback host, which is the real peer"
        else
          "allow_insecure_http covers loopback peers only"
        end
      end

      # Literal loopback addresses are recognized numerically; names are
      # accepted only for the RFC 6761 reserved "localhost" family, which
      # resolvers must keep on the loopback interface. Any other name is a
      # DNS lookup we cannot vouch for. See LOOPBACK_NAME.
      def loopback_host?(host)
        return false if host.nil?

        # URI#host keeps the brackets on an IPv6 literal.
        h = host.downcase.delete_prefix("[").delete_suffix("]")
        return true if h == LOOPBACK_NAME || h.end_with?(LOOPBACK_NAME_SUFFIX)

        literal = begin
          IPAddr.new(h)
        rescue IPAddr::Error
          nil
        end
        !literal.nil? && literal.loopback?
      end

      # Resolve the bearer token for the current request. A token_source
      # (callable) is consulted per request and wins over the static
      # bearer_token; returns nil when neither is configured.
      #
      # A configured token_source that yields a blank token is a hard error:
      # falling through would send an unauthenticated (or malformed
      # "Bearer ") request whose 401 looks like a credentials problem rather
      # than the real cause — the source produced nothing. Whitespace-only
      # counts as blank; it passes a bare empty? check but produces the same
      # broken header.
      def resolve_bearer_token
        if @token_source
          token = @token_source.call
          unless token.is_a?(String) && !token.strip.empty?
            raise TokenSourceError,
                  "token_source returned #{describe_token(token)}; " \
                  "expected a non-blank token string"
          end
          return token
        end

        @bearer_token
      end

      # Describe a rejected token by shape only. The value is never
      # rendered: TokenSourceError messages reach Rails logs, and a token
      # that merely failed *our* validation may still be live credential
      # material.
      def describe_token(token)
        return "nil" if token.nil?
        return "a blank string (#{token.length} whitespace characters)" if token.is_a?(String)

        "a #{token.class}"
      end

      # Construct a Net::HTTP instance configured per the constructor's
      # network keywords. Factored out so on-premises deploys (custom
      # timeouts, outbound proxy, private CA bundle) can be unit-tested
      # without making real HTTP calls.
      def build_http(uri)
        klass = if @proxy_uri
          Net::HTTP::Proxy(@proxy_uri.host, @proxy_uri.port, @proxy_uri.user, @proxy_uri.password)
        else
          Net::HTTP
        end
        http = klass.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        http.ca_file = @ca_file if @ca_file
        http.ca_path = @ca_path if @ca_path
        http
      end

      # FHIR helpers --------------------------------------------------------

      def build_patient_reference(resource)
        Corvid::PatientReference.new(
          identifier: resource["id"],
          display_name: format_human_name(resource.dig("name", 0)),
          dob: parse_date(resource["birthDate"]),
          sex: resource["gender"],
          ssn_last4: extract_ssn_last4(resource)
        )
      end

      def build_practitioner_reference(resource)
        Corvid::PractitionerReference.new(
          identifier: resource["id"],
          display_name: format_human_name(resource.dig("name", 0)),
          npi: extract_npi(resource),
          specialty: resource.dig("qualification", 0, "code", "coding", 0, "display")
        )
      end

      def claim_lines_from(claims)
        claims.each_with_object([]) do |claim, lines|
          built = safe_claim_lines(claim)
          return nil if built.nil?

          lines.concat(built)
        end
      end

      # A non-Hash item makes the whole claim read unknown. nil item means
      # the claim has no lines, which is an answer.
      def safe_claim_lines(claim)
        return nil unless claim_items_are_hashes?(claim)

        build_claim_line_references(claim)
      end

      def claim_items_are_hashes?(claim)
        raw = claim["item"]
        return true if raw.nil?
        return false unless raw.is_a?(Array)

        raw.all? { |item| item.is_a?(Hash) }
      end

      def build_claim_line_references(claim)
        patient_id = claim.dig("patient", "reference")&.sub("Patient/", "")
        provider_id = claim.dig("provider", "identifier", "value").presence ||
                      claim.dig("provider", "reference")&.split("/", -1)&.last.presence ||
                      claim.dig("provider", "display").presence
        claim_id = claim["id"]

        Array(claim["item"]).map do |item|
          coding = select_billing_coding(item)
          amount, amount_error = parse_billed_amount(item.dig("net", "value"))
          Corvid::ClaimLineReference.new(
            claim_identifier: claim_id,
            patient_identifier: patient_id,
            provider_identifier: provider_id,
            procedure_code: coding["code"],
            procedure_display: coding["display"].presence || item.dig("productOrService", "text").presence,
            serviced_date: parse_date(item["servicedDate"].presence || item.dig("servicedPeriod", "start")),
            billed_amount: amount,
            amount_error: amount_error,
            currency: item.dig("net", "currency") || "USD",
            sequence: item["sequence"]
          )
        end
      end

      # Pick the CPT/HCPCS coding used for pricing, not index 0 — a line may
      # list a clinical (SNOMED/LOINC) coding first. Falls back to the first
      # coding when no recognized billing system is present.
      def select_billing_coding(item)
        codings = Array(item.dig("productOrService", "coding"))
        codings.find { |c| BILLING_CODE_SYSTEMS.include?(c["system"]) } || codings.first || {}
      end

      # Returns [BigDecimal-or-nil, error-or-nil]. An ABSENT value is a legit
      # nil with no error. A PRESENT-but-unparseable value yields nil plus a
      # reason so callers surface the malformed line rather than silently
      # swallowing it to nil.
      def parse_billed_amount(value)
        return [ nil, nil ] if value.nil?

        [ BigDecimal(value.to_s), nil ]
      rescue ArgumentError
        # amount_error is surfaced to callers and reporting output, so the
        # server-supplied value is described, not echoed — same rule as the
        # auth path: nothing off the wire reaches a message verbatim.
        [ nil, "unparseable billed amount (#{describe_wire_value(value)})" ]
      end

      # Describe a server-supplied value by type/shape without echoing it.
      def describe_wire_value(value)
        return "null" if value.nil?
        return value.to_s if value == true || value == false
        return "a #{value.length}-character String" if value.is_a?(String)

        value.class.to_s.start_with?(/[AEIOU]/i) ? "an #{value.class}" : "a #{value.class}"
      end

      def build_referral_reference(resource)
        Corvid::ReferralReference.new(
          identifier: resource["id"],
          patient_identifier: resource.dig("subject", "reference")&.sub("Patient/", ""),
          status: resource["status"],
          reason_token: nil,
          estimated_cost: nil,
          medical_priority_level: priority_to_level(resource["priority"]),
          authorization_number: resource.dig("identifier", 0, "value"),
          emergent: resource["priority"] == "stat",
          urgent: resource["priority"] == "urgent",
          chs_approval_status: nil,
          service_requested: service_requested_label(resource),
          requesting_provider_identifier: resource.dig("requester", "reference")&.split("/")&.last
        )
      end

      # Empty or whitespace text is absent so coding.display can fill in.
      # Kept in plain Ruby: a list read builds this reference without
      # ActiveSupport loaded.
      def service_requested_label(resource)
        text = resource.dig("code", "text")
        return text if kept_label?(text)

        display = resource.dig("code", "coding", 0, "display")
        display if kept_label?(display)
      end

      def kept_label?(value)
        return false if value.nil?
        return false if value.is_a?(String) && value.match?(/\A[[:space:]]*\z/)

        true
      end

      def priority_to_level(priority)
        case priority
        when "stat"    then 1
        when "asap"    then 2
        when "urgent"  then 3
        when "routine" then 4
        end
      end

      def build_extension(url, value)
        case value
        when Numeric then { "url" => url, "valueDecimal" => value }
        when Date    then { "url" => url, "valueDate" => value.iso8601 }
        when Array   then { "url" => url, "valueString" => value.to_json }
        else              { "url" => url, "valueString" => value.to_s }
        end
      end

      def care_team_members(resource)
        (resource["participant"] || []).map { |participant| care_team_member(resource, participant) }
      end

      def care_team_member(resource, participant)
        Corvid::CareTeamMemberReference.new(
          practitioner_identifier: participant.dig("member", "reference")&.sub("Practitioner/", ""),
          role: participant.dig("role", 0, "coding", 0, "code"),
          name: resource["name"],
          status: resource["status"]
        )
      end

      # nil when the search did not answer; [] when it answered with no
      # matches. Same gates as #clinical_search (#search_bundle?, next link,
      # total). Only match-mode (or mode-less) entries of resource_type are
      # results. A blocking OperationOutcome, a malformed entry, or an entry
      # whose search is not a Hash or whose mode is not match, include, or
      # outcome is unknown.
      def references_from_search(resource_type, params)
        resources = list_search_resources(resource_type, params)
        return nil if resources.nil?

        resources.map { |resource| yield resource }
      end

      def list_search_resources(resource_type, params)
        bundle = validated_search(resource_type, params)
        return nil if bundle.nil?

        match_resources(bundle, resource_type)
      end

      def match_resources(bundle, resource_type)
        entries = clinical_bundle_entries(bundle)
        return nil if entries.nil?

        entries.each_with_object([]) do |entry, resources|
          resource = list_entry_resource(entry, resource_type)
          return nil if resource == :unknown

          resources << resource if resource
        end
      end

      def list_entry_resource(entry, resource_type)
        resource = entry_resource(entry)
        return :unknown if resource == :unknown
        return :unknown if blocking_list_outcome?(resource)
        return :unknown if malformed_entry_search?(entry)
        return unless typed_match_entry?(entry, resource_type)

        resource
      end

      def blocking_list_outcome?(resource)
        resource["resourceType"] == "OperationOutcome" && blocking_outcome?(resource)
      end

      def extract_entries(bundle)
        return [] unless bundle.is_a?(Hash) && bundle["entry"].is_a?(Array)

        bundle["entry"].filter_map { |e| e["resource"] }
      end

      def blank_patient_identifier?(patient_identifier)
        patient_identifier.nil? || patient_identifier.to_s.strip.empty?
      end

      def format_human_name(name_hash)
        return nil unless name_hash

        family = name_hash["family"]
        given = Array(name_hash["given"]).join(" ")
        [ family, given ].reject { |s| s.nil? || s.empty? }.join(", ")
      end

      def extract_ssn_last4(resource)
        ssn = Array(resource["identifier"]).find { |id| id["system"] == "http://hl7.org/fhir/sid/us-ssn" }
        ssn&.dig("value")&.last(4)
      end

      def extract_npi(resource)
        npi = Array(resource["identifier"]).find { |id| id["system"] == "http://hl7.org/fhir/sid/us-npi" }
        npi&.dig("value")
      end

      # Unknown enrollment, not a recorded denial: enrolled is nil.
      def tribal_enrollment_unavailable
        {
          enrolled: nil,
          membership_number: nil,
          tribe_name: nil,
          tribe_code: nil,
          member_status: nil,
          blood_quantum: nil,
          confidence: :unavailable,
          verified_at: Time.current
        }
      end

      def tribal_enrollment_from(ext)
        {
          enrolled: enrolled_value(ext),
          membership_number: sub_extension_value(ext, "membershipNumber"),
          tribe_name: sub_extension_value(ext, "tribeName"),
          tribe_code: sub_extension_value(ext, "tribeCode"),
          member_status: sub_extension_value(ext, "memberStatus"),
          blood_quantum: normalize_blood_quantum(blood_quantum_extension_value(ext)),
          confidence: tribal_confidence(ext),
          verified_at: Time.current
        }
      end

      # A missing or unrecognized confidence sub-extension is not :verified.
      # Only the exact documented spellings count; anything else, including
      # blank, other case, or a non-String value, fails closed.
      def tribal_confidence(ext)
        normalize_tribal_confidence(sub_extension_value(ext, "confidence"))
      end

      def blood_quantum_extension_value(extension)
        sub = Array(extension["extension"]).find { |entry| entry["url"] == "bloodQuantum" }
        return nil unless sub

        %w[valueDecimal valueInteger valueString].each do |key|
          return sub[key] if sub.key?(key)
        end

        nil
      end

      # A nil, empty, or whitespace-only resource_type is undetermined:
      # nil, never the first coverage. A requested type that matches
      # nothing is unknown — never another type's coverage.
      def coverage_for_resource_type(coverages, resource_type)
        return nil if resource_type.to_s.strip.empty?

        coverages.find { |coverage| coverage_type_matches?(coverage, resource_type) }
      end

      def coverage_type_matches?(coverage, resource_type)
        type_code = coverage.dig("type", "coding", 0, "code")
        return false if type_code.nil? || type_code.to_s.empty?

        requested = resource_type.to_s
        type_code == requested || type_code == COVERAGE_TYPE_MAP[requested]
      end

      def find_extension(resource, url)
        Array(resource["extension"]).find { |e| e["url"] == url }
      end

      # Exact boolean valueBoolean only. A missing enrolled sub-extension, or
      # any other FHIR value, is nil rather than a denial.
      def enrolled_value(extension)
        sub = Array(extension["extension"]).find { |entry| entry.is_a?(Hash) && entry["url"] == "enrolled" }
        return nil unless sub

        value = sub["valueBoolean"]
        value if value == true || value == false
      end

      def sub_extension_value(extension, sub_url)
        sub = Array(extension["extension"]).find { |e| e["url"] == sub_url }
        return nil unless sub
        return sub["valueBoolean"] if sub.key?("valueBoolean")

        sub["valueString"] || sub["valueDecimal"]
      end

      def format_address(address_hash)
        return nil unless address_hash

        line = Array(address_hash["line"]).join(" ")
        [ line, address_hash["city"], address_hash["state"] ].reject { |s| s.nil? || s.empty? }.join(", ")
      end

      def parse_date(value)
        return nil if value.nil? || value.to_s.empty?

        Date.parse(value.to_s)
      rescue ArgumentError
        nil
      end

      # Coverage period bounds only. A partial FHIR date ("2026" or
      # "2026-03") means its whole range: a start is the first day and an
      # end is the last day. Full dates parse as parse_date; malformed is nil.
      def parse_period_date(value, bound)
        range = partial_date_range(value.to_s)
        return parse_date(value) unless range

        bound == :start ? range.first : range.last
      rescue ArgumentError
        nil
      end

      def partial_date_range(text)
        case text
        when /\A(\d{4})\z/
          year = Regexp.last_match(1).to_i
          Date.new(year, 1, 1)..Date.new(year, 12, 31)
        when /\A(\d{4})-(\d{2})\z/
          first = Date.new(Regexp.last_match(1).to_i, Regexp.last_match(2).to_i, 1)
          first..first.next_month.prev_day
        end
      end

      # Coverage search -----------------------------------------------------

      def coverage_rows_from_pages(pages, patient_identifier)
        acc = { found: [], seen_ids: {}, received: 0, stated_total: nil, saw_total: false }
        pages.each do |bundle|
          return nil unless append_coverage_page(bundle, patient_identifier, acc)
        end
        coverage_search_result(acc[:found], acc[:received], acc[:stated_total])
      end

      def append_coverage_page(bundle, patient_identifier, acc)
        return false unless accept_coverage_page(bundle, acc)

        page = active_coverage_rows(bundle, patient_identifier, acc[:seen_ids])
        return false unless page

        acc[:received] += page[:coverage_count]
        acc[:found].concat(page[:coverages])
        true
      end

      def accept_coverage_page(bundle, acc)
        return false unless coverage_bundle_shape?(bundle)

        total = bundle["total"]
        stated = acc[:saw_total] ? acc[:stated_total] : total
        return false unless coverage_page_total_ok?(total, stated)

        acc[:stated_total] = total unless acc[:saw_total]
        acc[:saw_total] = true
      end

      def coverage_search_result(found, received, stated_total)
        return nil unless coverage_total_matches?(stated_total, received)

        found
      end

      def coverage_total_matches?(stated_total, received)
        return true if stated_total.nil?
        return false unless non_negative_coverage_total?(stated_total)

        stated_total == received
      end

      # A present total must be a non-negative Integer and the same value
      # as the first page. A later page may omit total.
      def coverage_page_total_ok?(page_total, stated_total)
        return true if page_total.nil?
        return false unless non_negative_coverage_total?(page_total)

        page_total == stated_total
      end

      def non_negative_coverage_total?(total)
        total.is_a?(Integer) && total >= 0
      end

      def coverage_bundle_shape?(bundle)
        bundle.is_a?(Hash) && bundle["type"] == "searchset" && coverage_strings_encoded?(bundle)
      end

      # Keys and values. One invalid string fails the whole search.
      def coverage_strings_encoded?(value)
        case value
        when String
          value.valid_encoding?
        when Array
          value.all? { |item| coverage_strings_encoded?(item) }
        when Hash
          value.all? { |key, item| coverage_strings_encoded?(key) && coverage_strings_encoded?(item) }
        else
          true
        end
      end

      def active_coverage_rows(bundle, patient_identifier, seen_ids)
        entries = bundle["entry"]
        return empty_coverage_page(bundle) if entries.nil?
        return nil unless entries.is_a?(Array)

        fold_coverage_entries(entries, patient_identifier, seen_ids)
      end

      # No entry array. Absent or a non-negative Integer total is an empty
      # page; the caller checks it against the first page and the count.
      # Any other total is incomplete.
      def empty_coverage_page(bundle)
        total = bundle["total"]
        return nil unless total.nil? || non_negative_coverage_total?(total)

        { coverages: [], coverage_count: 0 }
      end

      def fold_coverage_entries(entries, patient_identifier, seen_ids)
        rows = []
        count = 0
        entries.each do |entry|
          counted = append_coverage_entry(entry, rows, patient_identifier, seen_ids)
          return nil if counted.nil?

          count += counted
        end
        { coverages: rows, coverage_count: count }
      end

      def append_coverage_entry(entry, rows, patient_identifier, seen_ids)
        return nil unless well_formed_coverage_entry?(entry)
        return nil if unknown_coverage_entry_search?(entry)
        return nil if unknown_coverage_outcome?(entry)

        resource = coverage_resource(entry)
        return nil if resource && !remember_coverage_id(resource, seen_ids)
        return non_coverage_entry(entry) unless resource

        row = coverage_row(resource, patient_identifier)
        return nil if row == :unknown_coverage

        rows << row if row
        1
      rescue TypeError, NoMethodError, ArgumentError, EncodingError
        nil
      end

      # List reads (#entry_search_state) treat "include" and "outcome" as
      # known non-matches and keep the read. A Coverage row counts only for
      # :match (no search, no mode, or mode "match"); those two modes on a
      # Coverage entry are unknown. Every other malformed search is the
      # same predicate list reads use, and fails the whole read.
      def unknown_coverage_entry_search?(entry)
        return true if malformed_entry_search?(entry)
        return false unless coverage_resource(entry)

        entry_search_state(entry) != :match
      end

      # false fails the search. Inexact Coverage and OperationOutcome
      # types fail here. Any other String type is judged later.
      def well_formed_coverage_entry?(entry)
        resource = bundle_entry_resource(entry)
        return false unless resource

        accepted_resource_type?(resource["resourceType"])
      end

      def accepted_resource_type?(type)
        type.is_a?(String) && !inexact_coverage_type?(type) && !inexact_outcome_type?(type)
      end

      def inexact_coverage_type?(type)
        type != "Coverage" && type.casecmp?("Coverage")
      end

      def inexact_outcome_type?(type)
        type != "OperationOutcome" && type.strip.casecmp?("OperationOutcome")
      end

      # false fails the search. The id is a non-empty String, unique across
      # every page of this search, including coverages later filtered out.
      def remember_coverage_id(resource, seen_ids)
        id = resource["id"]
        return false unless id.is_a?(String) && !id.empty?
        return false if seen_ids.key?(id)

        seen_ids[id] = true
      end

      def bundle_entry_resource(entry)
        resource = entry.is_a?(Hash) ? entry["resource"] : nil
        resource if resource.is_a?(Hash)
      end

      # A missing issue, an empty Array, a non-Array, a non-Hash element,
      # or a severity outside COVERAGE_OUTCOME_SEVERITIES is unknown.
      # issue.code uses the same predicate as every other OperationOutcome
      # read (#blocking_issue?): a missing code, a non-String, or any
      # other value that is not a plain-ASCII FHIR code token is unknown.
      # UNTRUSTED_OUTCOME_CODES block at any severity.
      # error and fatal still block. A well-formed warning or information
      # issue with another code token does not.
      def unknown_coverage_outcome?(entry)
        resource = operation_outcome_resource(entry)
        return false unless resource

        unknown_coverage_issues?(resource["issue"])
      end

      def operation_outcome_resource(entry)
        resource = bundle_entry_resource(entry)
        resource if resource && resource["resourceType"] == "OperationOutcome"
      end

      def unknown_coverage_issues?(issues)
        return true unless issues.is_a?(Array)
        return true if issues.empty?

        issues.any? { |issue| unknown_coverage_issue?(issue) }
      end

      def unknown_coverage_issue?(issue)
        return true unless issue.is_a?(Hash)
        return true unless COVERAGE_OUTCOME_SEVERITIES.include?(issue["severity"])

        blocking_issue?(issue)
      end

      # 0 skips the entry. nil fails the search. Exact OperationOutcome
      # was already accepted. search.mode "include" may carry other types.
      def non_coverage_entry(entry)
        return 0 if operation_outcome_resource(entry) || included_other_resource?(entry)

        nil
      end

      def included_other_resource?(entry)
        resource = bundle_entry_resource(entry)
        return false unless resource

        ignorable_include?(entry, resource, "Coverage")
      end

      def coverage_resource(entry)
        resource = bundle_entry_resource(entry)
        resource if resource && resource["resourceType"] == "Coverage"
      end

      def coverage_row(resource, patient_identifier)
        return :unknown_coverage unless trusted_coverage?(resource, patient_identifier)

        period_state = coverage_period_current?(resource)
        return :unknown_coverage if period_state == :unknown_coverage
        insurance = insurance_coverage_state(resource)
        return :unknown_coverage if insurance == :unknown_coverage
        plan_name = coverage_plan_name(resource)
        return :unknown_coverage if plan_name == :unknown_coverage
        return nil unless period_state && resource["status"] == "active" && insurance

        coverage_attributes(resource, plan_name)
      end

      def trusted_coverage?(resource, patient_identifier)
        coverage_beneficiary_matches?(resource, patient_identifier) &&
          known_coverage_status?(resource["status"]) &&
          trusted_coverage_strings?(resource)
      end

      def trusted_coverage_strings?(resource)
        coverage_string_or_nil?(coverage_payor_display(resource)) &&
          coverage_string_or_nil?(resource["subscriberId"]) &&
          trusted_type_codes?(resource)
      end

      def coverage_string_or_nil?(value)
        value.nil? || value.is_a?(String)
      end

      # Every type.coding code is nil or a String, or Integer 9 on the X12
      # claim-filing system (self-pay). Any other non-String code is unknown.
      def trusted_type_codes?(resource)
        codings = coverage_type_codings(resource)
        return false if codings == :unknown_coverage

        codings.all? { |coding| trusted_coding_code?(coding) }
      end

      def trusted_coding_code?(coding)
        return false unless coding.is_a?(Hash)

        code = coding["code"]
        return true if coverage_string_or_nil?(code)

        x12_self_pay?(code, coding["system"])
      end

      def known_coverage_status?(status)
        status.is_a?(String) && COVERAGE_STATUSES.include?(status)
      end

      def insurance_coverage_state(resource)
        codings = coverage_type_codings(resource)
        return :unknown_coverage if codings == :unknown_coverage

        payors = coverage_payors(resource)
        return :unknown_coverage if payors == :unknown_coverage

        insurance_allowlisted?(resource, codings, payors)
      end

      def insurance_allowlisted?(resource, codings, payors)
        kind = coverage_kind_state(resource)
        return kind if kind == :unknown_coverage
        return false if kind == :exclude
        return false unless organization_payors?(payors)
        return false if self_pay_type_text?(resource, codings)

        codings.all? { |coding| insurance_type_coding?(coding) }
      end

      def coverage_kind_state(resource)
        return :allow unless resource.key?("kind")

        kind = resource["kind"]
        return :allow if kind == COVERAGE_INSURANCE_KIND
        return :exclude if COVERAGE_EXCLUDED_KINDS.include?(kind)

        :unknown_coverage
      end

      def coverage_type_codings(resource)
        type = resource["type"]
        return [] if type.nil?
        return :unknown_coverage unless type.is_a?(Hash)

        coding_entries(type["coding"])
      end

      def coding_entries(coding)
        return [] if coding.nil?
        return :unknown_coverage unless coding.is_a?(Array)
        return :unknown_coverage unless coding.all? { |row| row.is_a?(Hash) }

        coding
      end

      def coverage_payors(resource)
        payors = resource["payor"]
        return [] if payors.nil?
        return :unknown_coverage unless payors.is_a?(Array)
        return :unknown_coverage unless payors.all? { |payor| payor.is_a?(Hash) }

        payors
      end

      def organization_payors?(payors)
        return false if payors.empty?

        payors.all? { |payor| organization_reference?(payor["reference"]) }
      end

      def organization_reference?(reference)
        return false unless reference.is_a?(String)

        organization_prefixed?(reference, "Organization/") ||
          organization_prefixed?(reference, "#{@base_url}/Organization/")
      end

      def organization_prefixed?(reference, prefix)
        return false unless reference.start_with?(prefix)

        COVERAGE_REFERENCE_ID_RE.match?(reference.delete_prefix(prefix))
      end

      def self_pay_coding?(coding)
        code = coding["code"]
        system = coding["system"]
        pay_self_pay?(code, system) || x12_self_pay?(code, system)
      end

      def pay_self_pay?(code, system)
        code == COVERAGE_SELF_PAY_CODE && pay_self_pay_system?(system)
      end

      def pay_self_pay_system?(system)
        system.nil? || COVERAGE_PAY_SELF_PAY_SYSTEMS.include?(system)
      end

      def x12_self_pay?(code, system)
        return code == COVERAGE_X12_SELF_PAY_CODE if system.nil?
        return false unless system == COVERAGE_X12_CLAIM_FILING_INDICATOR_SYSTEM

        x12_claim_filing_self_pay_code?(code)
      end

      def x12_claim_filing_self_pay_code?(code)
        code == COVERAGE_X12_SELF_PAY_CODE ||
          code == COVERAGE_X12_SELF_PAY_SHORT_CODE ||
          (code.is_a?(Integer) && code == COVERAGE_X12_SELF_PAY_INTEGER)
      end

      # Issue #607. A PHDSC SOP coding that is not an insurer family
      # excludes the Coverage, including when another coding is insurance.
      def sop_non_insurer_coding?(coding)
        return false unless sop_system?(coding["system"])

        !sop_insurer_code?(coding["code"])
      end

      def sop_system?(system)
        COVERAGE_SOP_SYSTEMS.include?(system)
      end

      def sop_insurer_code?(code)
        code.is_a?(String) && COVERAGE_SOP_INSURER_CODE_RE.match?(code)
      end

      def insurance_type_coding?(coding)
        !self_pay_coding?(coding) && !sop_non_insurer_coding?(coding)
      end

      # Issue #607. type.text applies only when there is no coding. Self-pay
      # only when downcasing and removing whitespace and hyphens yields
      # "selfpay".
      def self_pay_type_text?(resource, codings)
        return false unless codings.empty?

        text = coverage_type_text(resource)
        text.is_a?(String) && normalized_self_pay_text(text) == COVERAGE_SELF_PAY_TEXT
      end

      def normalized_self_pay_text(text)
        text.downcase.gsub(/[[:space:]]|-/, "")
      end

      def coverage_type_text(resource)
        type = resource["type"]
        type.is_a?(Hash) ? type["text"] : nil
      end

      def coverage_beneficiary_matches?(resource, patient_identifier)
        beneficiary = resource["beneficiary"]
        return false unless beneficiary.is_a?(Hash)

        reference = beneficiary["reference"]
        return false unless reference.is_a?(String)

        relative = "Patient/#{patient_identifier}"
        reference == relative || reference == "#{@base_url}/#{relative}"
      end

      # Clinical search -------------------------------------------------------
      # One page only. nil means unknown; never a partial list. A Bundle.link
      # entry with relation "next" is unknown. Response bodies are not logged
      # (ADR 0003). Bundle.type must be searchset. A positive total counts
      # only with a match-mode entry (mode absent or "match") whose resource
      # has the searched resourceType.

      # Goes through #fhir_search so an override (FhirDemoAdapter) can serve
      # the page from memory. Blank ids are unknown and must not hit the wire.
      def clinical_search(resource_type, patient_identifier)
        return nil if patient_identifier.blank?

        bundle = validated_search(resource_type, { patient: patient_identifier })
        return nil if bundle.nil?

        yield bundle
      rescue *CLINICAL_READ_ERRORS
        nil
      end

      # One answered search page, or nil. A transport failure is unknown.
      # Pass a block to replace the #search_bundle? check; next-link and
      # total gates stay the same.
      def validated_search(resource_type, params, &accept)
        bundle = fhir_search(resource_type, params)
        return nil unless accept ? accept.call(bundle) : search_bundle?(bundle)
        return nil if next_page_link?(bundle)
        return nil unless consistent_search_total?(bundle, resource_type)

        bundle
      rescue *CLINICAL_READ_ERRORS
        nil
      end

      def search_bundle?(parsed)
        return false unless parsed.is_a?(Hash)
        return false unless parsed["resourceType"] == "Bundle"

        parsed["type"] == "searchset"
      end

      def next_page_link?(bundle)
        links = bundle["link"]
        return false unless links.is_a?(Array)

        links.any? { |link| link.is_a?(Hash) && link["relation"] == "next" }
      end

      def consistent_search_total?(bundle, resource_type)
        total = bundle["total"]
        return true if total.nil?
        return false unless total.is_a?(Integer)
        return true unless total.positive?

        any_match_entry?(bundle, resource_type)
      end

      def any_match_entry?(bundle, resource_type)
        entries = bundle["entry"]
        return false unless entries.is_a?(Array)

        entries.any? { |entry| typed_match_entry?(entry, resource_type) }
      end

      def typed_match_entry?(entry, resource_type)
        return false unless match_mode_entry?(entry)

        resource = entry["resource"]
        resource.is_a?(Hash) && resource["resourceType"] == resource_type
      end

      def match_mode_entry?(entry)
        entry.is_a?(Hash) && entry_search_state(entry) == :match
      end

      # :match, :other, or :malformed. Absent search or an absent mode is a
      # match. include and outcome are known non-matches. Anything else,
      # including a search value that is not a Hash, is malformed. List reads
      # treat :malformed as unknown. fhir_search total and duplicate counts
      # do not: see #search_match_entry?.
      def entry_search_state(entry)
        search = entry["search"]
        return :match if search.nil?
        return :malformed unless search.is_a?(Hash)

        case search["mode"]
        when nil, "match" then :match
        when "include", "outcome" then :other
        else :malformed
        end
      end

      def malformed_entry_search?(entry)
        entry.is_a?(Hash) && entry_search_state(entry) == :malformed
      end

      # Clinical reads. A missing or null entry is no rows. A present entry
      # that is not an Array is unknown (nil); callers treat that nil as the
      # search not answering.
      def clinical_bundle_entries(bundle)
        entries = bundle["entry"]
        return [] if entries.nil?
        return nil unless entries.is_a?(Array)

        entries
      end

      def entry_resource(entry)
        return :unknown unless entry.is_a?(Hash)

        resource = entry["resource"]
        return :unknown unless resource.is_a?(Hash)

        resource
      end

      def blocking_outcome?(resource)
        issues = resource["issue"]
        return false if issues.nil?
        return true unless issues.is_a?(Array)

        issues.any? { |issue| blocking_issue?(issue) }
      end

      # FHIR R4 requires OperationOutcome.issue.code (1..1). Malformed
      # means unknown: an issue is blocking unless its code is a
      # plain-ASCII FHIR code token. A missing key, JSON null, a
      # non-String, invalid encoding, look-alike characters, padding,
      # and "" are unknown at any severity.
      def blocking_issue?(issue)
        return true unless issue.is_a?(Hash)
        return true unless fhir_code_token?(issue["code"])

        untrusted_outcome?(issue) || blocking_severity?(issue)
      end

      def untrusted_outcome?(issue)
        code = normalized_outcome_code(issue["code"])
        !code.nil? && UNTRUSTED_OUTCOME_CODES.include?(code)
      end

      # Downcased FHIR_CODE_TOKEN for UNTRUSTED_OUTCOME_CODES. A value that
      # is not that token is nil. No Unicode space or format stripping, and
      # no other rewrite.
      def normalized_outcome_code(code)
        return unless fhir_code_token?(code)

        code.downcase
      end

      def fhir_code_token?(code)
        code.is_a?(String) && code.valid_encoding? && FHIR_CODE_TOKEN.match?(code)
      end

      def blocking_severity?(issue)
        severity = issue["severity"]
        severity.is_a?(String) && BLOCKING_OUTCOME_SEVERITIES.include?(severity.downcase)
      end

      def unknown_value?(*values)
        values.any? { |value| value == :unknown }
      end

      def optional_string(value)
        return nil if value.nil?
        return :unknown unless value.is_a?(String)
        return nil if value.blank?

        value
      end

      # Full day precision becomes a Date. A grammar-valid partial (year or
      # year-month) is nil so the row is kept. Anything else is unknown.
      def strict_date(value)
        match = FHIR_DATETIME.match(value)
        return :unknown unless match
        return nil unless match[:day]

        calendar_date(match)
      end

      def calendar_date(match)
        Date.new(match[:year].to_i, match[:month].to_i, match[:day].to_i)
      rescue ArgumentError
        :unknown
      end

      def subject_matches?(resource, patient_identifier)
        subject = resource["subject"]
        return false unless subject.is_a?(Hash)

        patient_reference?(subject["reference"], patient_identifier)
      end

      def patient_reference?(reference, patient_identifier)
        return false unless reference.is_a?(String)

        relative = "Patient/#{patient_identifier}"
        reference == relative || reference == "#{@base_url}/#{relative}"
      end

      def coverage_period_current?(resource)
        period = resource["period"]
        return true if period.nil?
        return :unknown_coverage unless period.is_a?(Hash)

        start_state = coverage_bound_current?(period["start"], :start)
        return :unknown_coverage if start_state == :unknown_coverage

        end_state = coverage_bound_current?(period["end"], :end)
        return :unknown_coverage if end_state == :unknown_coverage

        start_state && end_state
      end

      # true / false keep or drop the row. :unknown_coverage fails the search.
      def coverage_bound_current?(raw, role)
        parsed = parse_coverage_bound(raw, role)
        return true if parsed.nil?
        return :unknown_coverage unless parsed.is_a?(Hash)

        point = parsed[:compare]
        now = point.is_a?(Time) ? Time.current : Date.current
        role == :start ? point <= now : point >= now
      end

      def coverage_bound_date(raw, role)
        parsed = parse_coverage_bound(raw, role)
        parsed.is_a?(Hash) ? parsed[:mapped] : nil
      end

      # nil is an open bound. :unknown_coverage is present but not strict
      # FHIR date or dateTime. A hash carries the compare point and the
      # calendar date copied onto the returned row.
      def parse_coverage_bound(raw, role)
        return nil if raw.nil? || raw == ""
        return :unknown_coverage unless raw.is_a?(String)

        if COVERAGE_YEAR_RE.match?(raw)
          coverage_year_bound(raw, role)
        elsif COVERAGE_MONTH_RE.match?(raw)
          coverage_month_bound(raw, role)
        elsif COVERAGE_DATE_RE.match?(raw)
          coverage_day_bound(raw)
        elsif COVERAGE_DATETIME_RE.match?(raw)
          coverage_instant_bound(raw)
        else
          :unknown_coverage
        end
      end

      def coverage_year_bound(raw, role)
        year = raw.to_i
        date = role == :start ? Date.new(year, 1, 1) : Date.new(year, 12, 31)
        { compare: date, mapped: date }
      rescue ArgumentError
        :unknown_coverage
      end

      def coverage_month_bound(raw, role)
        year_text, month_text = raw.split("-", 2)
        month = month_text.to_i
        return :unknown_coverage unless (1..12).cover?(month)

        year = year_text.to_i
        date = role == :start ? Date.new(year, month, 1) : Date.new(year, month, -1)
        { compare: date, mapped: date }
      rescue ArgumentError
        :unknown_coverage
      end

      def coverage_day_bound(raw)
        year, month, day = raw.split("-").map(&:to_i)
        date = Date.new(year, month, day)
        { compare: date, mapped: date }
      rescue ArgumentError
        :unknown_coverage
      end

      def coverage_instant_bound(raw)
        instant = Time.iso8601(raw)
        utc = instant.getutc
        { compare: instant, mapped: Date.new(utc.year, utc.month, utc.day) }
      rescue ArgumentError
        :unknown_coverage
      end

      def coverage_attributes(resource, plan_name)
        {
          payer_name: coverage_payor_display(resource),
          plan_name: plan_name,
          coverage_type: coverage_primary_type_code(resource),
          policy_number: resource["subscriberId"],
          coverage_start: coverage_bound_date(coverage_period_bound(resource, "start"), :start),
          coverage_end: coverage_bound_date(coverage_period_bound(resource, "end"), :end),
          status: resource["status"]
        }
      end

      def coverage_payor_display(resource)
        payors = resource["payor"]
        return nil unless payors.is_a?(Array)

        first = payors.first
        first.is_a?(Hash) ? first["display"] : nil
      end

      def coverage_primary_type_code(resource)
        codings = coverage_type_codings(resource)
        return nil unless codings.is_a?(Array) && !codings.empty?

        codings.first["code"]
      end

      def coverage_period_bound(resource, key)
        period = resource["period"]
        period.is_a?(Hash) ? period[key] : nil
      end

      def coverage_plan_name(resource)
        classes = resource["class"]
        return nil unless classes.is_a?(Array)

        plan = coverage_plan_class(classes)
        return :unknown_coverage if plan == :unknown_coverage
        return nil unless plan.is_a?(Hash)

        [ plan["name"], plan["value"] ].find { |item| item.is_a?(String) && !item.empty? }
      end

      def coverage_plan_class(classes)
        plan = nil
        classes.each do |row|
          code = coverage_class_code(row)
          return :unknown_coverage if code == :unknown_coverage

          plan = row if plan.nil? && code == "plan"
        end
        plan
      end

      def coverage_class_code(row)
        return :unknown_coverage unless row.is_a?(Hash)

        type = row["type"]
        return nil if type.nil?
        return :unknown_coverage unless type.is_a?(Hash)

        first_coding_code(type["coding"])
      end

      def first_coding_code(coding)
        rows = coding_entries(coding)
        return rows if rows == :unknown_coverage
        return nil if rows.empty?

        rows.first["code"]
      end

      # Conditions ------------------------------------------------------------

      def map_condition_entries(bundle, patient_identifier)
        entries = clinical_bundle_entries(bundle)
        return nil if entries.nil?

        entries.each_with_object([]) do |entry, results|
          mapped = condition_from_entry(entry, patient_identifier)
          return nil if mapped == :unknown

          results << mapped if mapped.is_a?(Corvid::ConditionReference)
        end
      end

      def condition_from_entry(entry, patient_identifier)
        resource = entry_resource(entry)
        return :unknown if resource == :unknown
        return nil if ignorable_include?(entry, resource, "Condition")

        map_condition_resource(resource, patient_identifier)
      end

      # search.mode include may carry other resource types. Those are skipped.
      # Any other unexpected type makes the page unknown.
      def ignorable_include?(entry, resource, *types)
        return false unless include_entry?(entry)
        return false if types.include?(resource["resourceType"])
        return false if resource["resourceType"] == "OperationOutcome"

        true
      end

      def include_entry?(entry)
        search = entry["search"]
        search.is_a?(Hash) && search["mode"] == "include"
      end

      def map_condition_resource(resource, patient_identifier)
        case resource["resourceType"]
        when "OperationOutcome"
          blocking_outcome?(resource) ? :unknown : nil
        when "Condition"
          build_condition_reference(resource, patient_identifier)
        else
          :unknown
        end
      end

      def build_condition_reference(resource, patient_identifier)
        return :unknown unless subject_matches?(resource, patient_identifier)

        marker = verification_marker(resource)
        assembled = assemble_condition(resource)
        condition_result(marker, assembled)
      end

      def condition_result(marker, assembled)
        return :unknown if marker == :unknown || assembled == :unknown
        return nil if marker == :skip

        assembled
      end

      def assemble_condition(resource)
        category = us_core_category(resource)
        status = clinical_status_code(resource)
        parts = codeable_parts(resource["code"])
        onset = onset_date_for(resource)
        return :unknown if unknown_value?(category, status, parts, onset)
        return :unknown if unusable_clinical_status?(resource, status)
        return nil unless include_condition?(category, status)

        condition_reference(parts, status, category, onset)
      end

      # Missing, text-only, or non-condition-clinical status makes the page
      # unknown. entered-in-error, coded or text-only, still drops the row.
      def unusable_clinical_status?(resource, status)
        status.nil? && !entered_in_error?(resource)
      end

      def entered_in_error?(resource)
        status = resource["verificationStatus"]
        codings = status_codings(status)
        return false if codings == :unknown
        return verification_text(status) == "entered-in-error" if uncoded_verification?(codings)

        codings.any? { |coding| coding["code"] == "entered-in-error" }
      end

      def verification_marker(resource)
        status = resource["verificationStatus"]
        codings = status_codings(status)
        return :unknown if codings == :unknown
        return text_verification_marker(status) if uncoded_verification?(codings)
        return :skip if codings.any? { |coding| excluded_verification_coding?(coding) }

        :ok
      end

      def uncoded_verification?(codings)
        codings.nil? || codings.empty?
      end

      # Text alone excludes refuted and entered-in-error. Other text does not.
      def text_verification_marker(status)
        return :skip if EXCLUDED_VERIFICATION_STATUSES.include?(verification_text(status))

        :ok
      end

      # Stripped, case-insensitive verificationStatus.text. nil when absent
      # or not a string.
      def verification_text(status)
        return nil unless status.is_a?(Hash)

        text = status["text"]
        return nil unless text.is_a?(String)

        text.strip.downcase
      end

      # refuted and entered-in-error exclude the row in any code system.
      def excluded_verification_coding?(coding)
        code = coding["code"]
        code.is_a?(String) && EXCLUDED_VERIFICATION_STATUSES.include?(code)
      end

      def include_condition?(category, status)
        US_CORE_CONDITION_CATEGORIES.include?(category) &&
          INCLUDED_CLINICAL_STATUSES.include?(status)
      end

      def condition_reference(parts, status, category, onset)
        Corvid::ConditionReference.new(
          code: parts[0],
          code_system: parts[1],
          display: parts[2],
          clinical_status: status,
          category: category,
          onset_date: onset
        )
      end

      # nil: a known system has an explicit out-of-scope code (skip).
      # :unknown: no known system, a missing, nil, or blank code in a
      # known system, or a malformed element.
      def us_core_category(resource)
        categories = resource["category"]
        return :unknown if categories.nil? || !categories.is_a?(Array) || categories.empty?

        scan_categories(categories)
      end

      def scan_categories(categories)
        saw_system = false
        match = nil
        categories.each do |category|
          code = category_match(category)
          return :unknown if code == :unknown

          saw_system ||= category_system_code?(code)
          match ||= code if code.is_a?(String)
        end
        return :unknown unless saw_system

        match
      end

      def category_match(category)
        return :unknown unless category.is_a?(Hash)

        codings = category["coding"]
        return nil if codings.nil?
        return :unknown unless codings.is_a?(Array)

        scan_category_codings(codings)
      end

      def scan_category_codings(codings)
        saw_system = false
        match = nil
        codings.each do |coding|
          code = matching_category_code(coding)
          return :unknown if code == :unknown

          saw_system ||= category_system_code?(code)
          match ||= code if code.is_a?(String)
        end
        return :excluded if saw_system && match.nil?

        match
      end

      def category_system_code?(code)
        code == :excluded || code.is_a?(String)
      end

      def matching_category_code(coding)
        return :unknown unless coding.is_a?(Hash)
        return nil unless KNOWN_CONDITION_CATEGORY_SYSTEMS.include?(coding["system"])

        category_code_value(coding["code"])
      end

      def category_code_value(raw)
        code = optional_string(raw)
        return :unknown unless code.is_a?(String)
        return :excluded unless US_CORE_CONDITION_CATEGORIES.include?(code)

        code
      end

      def clinical_status_code(resource)
        codings = status_codings(resource["clinicalStatus"])
        return codings if codings.nil? || codings == :unknown

        selected = clinical_value_codings(codings)
        return nil if selected.empty?

        agreed_clinical_code(selected)
      end

      # Official condition-clinical codings win, in any position. Codes that
      # disagree make the page unknown; identical repeats are one value. A
      # coding with no system is that value set only when no official coding
      # is present. Other systems are ignored.
      def clinical_value_codings(codings)
        official = codings.select { |coding| coding["system"] == CONDITION_CLINICAL_SYSTEM }
        return official if official.any?

        codings.select { |coding| absent_system?(coding) }
      end

      def agreed_clinical_code(codings)
        codes = codings.map { |coding| optional_string(coding["code"]) }
        return :unknown if unknown_value?(*codes) || codes.uniq.size > 1

        clinical_code_value(codes.first)
      end

      def clinical_code_value(code)
        return code if code.nil?
        return :unknown unless FHIR_CLINICAL_STATUSES.include?(code)

        code
      end

      def absent_system?(coding)
        system = coding["system"]
        system.nil? || (system.is_a?(String) && system.blank?)
      end

      def status_codings(status)
        return nil if status.nil?
        return :unknown unless status.is_a?(Hash)

        codings = status["coding"]
        return nil if codings.nil?
        return :unknown unless codings.is_a?(Array) && codings.all? { |coding| coding.is_a?(Hash) }

        codings
      end

      def onset_date_for(resource)
        primary = optional_string(resource["onsetDateTime"])
        fallback = period_start(resource["onsetPeriod"])
        return :unknown if unknown_value?(primary, fallback)

        raw = primary || fallback
        return nil if raw.nil?

        strict_date(raw)
      end

      def period_start(period)
        return nil if period.nil?
        return :unknown unless period.is_a?(Hash)

        start = period["start"]
        return nil if start.nil? || (start.is_a?(String) && start.blank?)
        return :unknown unless start.is_a?(String)

        start
      end

      # Absent code element is unknown. Otherwise the first coding with a
      # non-empty code supplies code, system, and display; display then falls
      # back to text. No such coding and no text is unknown.
      def codeable_parts(codeable)
        return :unknown unless codeable.is_a?(Hash)

        coding = first_coded_coding(codeable["coding"])
        return :unknown if coding == :unknown

        assemble_codeable(coding, codeable["text"])
      end

      def assemble_codeable(coding, text)
        return text_only_parts(text) if coding.nil?

        code = optional_string(coding["code"])
        system = optional_string(coding["system"])
        display = optional_string(coding["display"])
        fallback = optional_string(text)
        return :unknown if unknown_value?(code, system, display, fallback)

        [ code, system, display || fallback ]
      end

      def text_only_parts(text)
        display = optional_string(text)
        return :unknown unless display.is_a?(String)

        [ nil, nil, display ]
      end

      def first_coded_coding(codings)
        return nil if codings.nil?
        return :unknown unless codings.is_a?(Array)
        return :unknown unless codings.all? { |coding| coding.is_a?(Hash) }

        codings.each do |coding|
          state = code_presence(coding["code"])
          return :unknown if state == :unknown
          return coding if state == :coded
        end
        nil
      end

      def code_presence(code)
        return :absent if code.nil? || (code.is_a?(String) && code.blank?)
        return :unknown unless code.is_a?(String)

        :coded
      end

      # Medications -----------------------------------------------------------

      def map_medication_entries(bundle, patient_identifier)
        entries = clinical_bundle_entries(bundle)
        return nil if entries.nil?

        collected = partition_medication_entries(entries)
        return nil if collected.nil?

        medication_references(collected[0], patient_identifier, collected[1])
      end

      def partition_medication_entries(entries)
        index = {}
        requests = []
        entries.each do |entry|
          classified = classify_medication_entry(entry, index)
          return nil if classified == :unknown

          requests << classified if medication_request?(classified)
        end
        [ requests, index ]
      end

      def medication_request?(resource)
        resource.is_a?(Hash) && resource["resourceType"] == "MedicationRequest"
      end

      def classify_medication_entry(entry, index)
        resource = entry_resource(entry)
        return :unknown if resource == :unknown
        return nil if ignorable_include?(entry, resource, "Medication", "MedicationRequest")

        case resource["resourceType"]
        when "OperationOutcome"
          blocking_outcome?(resource) ? :unknown : nil
        when "Medication"
          index_medication(index, entry, resource)
        when "MedicationRequest"
          resource
        else
          :unknown
        end
      end

      def index_medication(index, entry, resource)
        id = resource["id"]
        return :unknown unless id.is_a?(String) && id.present?
        return nil unless trusted_medication_entry?(entry, id)
        return :unknown if index.key?(id)

        index[id] = resource
        nil
      end

      # Absent fullUrl, relative Medication/<id>, or base_url/Medication/<id>.
      # Any other fullUrl is a different resource and does not satisfy a local
      # Medication/<id> reference.
      def trusted_medication_entry?(entry, id)
        full_url = entry["fullUrl"]
        return true if full_url.nil?

        medication_full_url?(full_url, id)
      end

      def medication_full_url?(full_url, id)
        return false unless full_url.is_a?(String)

        relative = "Medication/#{id}"
        full_url == relative || full_url == "#{@base_url}/#{relative}"
      end

      def medication_references(requests, patient_identifier, index)
        requests.each_with_object([]) do |request, results|
          disposition = medication_disposition(request, patient_identifier)
          return nil if disposition == :unknown
          next if disposition == :skip

          mapped = build_medication_reference(request, patient_identifier, index)
          return nil if mapped.nil?

          results << mapped
        end
      end

      # Subject is checked before exclusions. Another patient's request
      # makes the page unknown even when the row would be excluded.
      # Unknown status or a non-boolean doNotPerform does too. Boolean
      # true and entered-in-error drop a matching row. False and absence
      # stay.
      def medication_disposition(request, patient_identifier)
        return :unknown unless subject_matches?(request, patient_identifier)

        perform = do_not_perform_disposition(request)
        return :unknown if perform == :unknown
        return :unknown unless known_medication_status?(request)
        return :skip if perform == :skip || medication_entered_in_error?(request)

        :keep
      end

      def do_not_perform_disposition(request)
        case request["doNotPerform"]
        when true       then :skip
        when false, nil then :keep
        else :unknown
        end
      end

      def known_medication_status?(request)
        status = request["status"]
        status.is_a?(String) && MEDICATION_REQUEST_STATUSES.include?(status)
      end

      def medication_entered_in_error?(request)
        request["status"] == "entered-in-error"
      end

      def build_medication_reference(request, patient_identifier, index)
        return nil unless subject_matches?(request, patient_identifier)

        parts = medication_code_parts(request, index)
        authored = authored_on_for(request)
        dosage = dosage_text_for(request)
        status = optional_string(request["status"])
        return nil if medication_unknown?(parts, authored, dosage, status)

        medication_reference(parts, status, authored, dosage)
      end

      def medication_unknown?(parts, authored, dosage, status)
        parts.nil? || unknown_value?(parts, authored, dosage, status)
      end

      def medication_reference(parts, status, authored, dosage)
        Corvid::MedicationReference.new(
          code: parts[0],
          code_system: parts[1],
          display: parts[2],
          status: status,
          authored_on: authored,
          dosage_text: dosage
        )
      end

      def medication_code_parts(request, index)
        if concept_present?(request)
          parts = codeable_parts(request["medicationCodeableConcept"])
          return nil if parts == :unknown

          return parts
        end

        referenced_code_parts(request, index)
      end

      def concept_present?(request)
        concept = request["medicationCodeableConcept"]
        return false if concept.nil?
        return true unless concept.is_a?(Hash)

        codeable_content?(concept)
      end

      def codeable_content?(concept)
        text_content?(concept["text"]) || any_coding_content?(concept["coding"])
      end

      def any_coding_content?(codings)
        return false unless codings.is_a?(Array)

        codings.any? { |coding| coding_content?(coding) }
      end

      def coding_content?(coding)
        coding.is_a?(Hash) && (text_content?(coding["code"]) || text_content?(coding["display"]))
      end

      def text_content?(text)
        text.is_a?(String) && text.present?
      end

      def referenced_code_parts(request, index)
        medication = resolve_medication(request, index)
        return nil if medication.nil? || medication == :unknown
        return nil unless medication_has_code?(medication)

        parts = codeable_parts(medication["code"])
        return nil if parts == :unknown

        parts
      end

      def medication_has_code?(medication)
        code = medication["code"]
        code.is_a?(Hash) && codeable_content?(code)
      end

      def resolve_medication(request, index)
        reference = medication_reference_string(request["medicationReference"])
        return reference if reference.nil? || reference == :unknown

        if reference.start_with?("#")
          contained_medication(request, reference.delete_prefix("#"))
        else
          bundled_medication(index, reference)
        end
      end

      def medication_reference_string(reference)
        return nil unless reference.is_a?(Hash)

        optional_string(reference["reference"])
      end

      def contained_medication(request, id)
        medications = contained_medications(request)
        return medications if medications.nil? || medications == :unknown
        return :unknown if duplicate_medication_ids?(medications)

        medications.find { |resource| resource["id"] == id }
      end

      def contained_medications(request)
        contained = request["contained"]
        return nil if contained.nil?
        return :unknown unless contained_list?(contained)

        contained.select { |resource| resource["resourceType"] == "Medication" }
      end

      def contained_list?(contained)
        contained.is_a?(Array) && contained.all? { |resource| resource.is_a?(Hash) }
      end

      def duplicate_medication_ids?(medications)
        ids = medications.map { |resource| resource["id"] }
        ids.uniq.size != ids.size
      end

      def bundled_medication(index, reference)
        id = medication_id_from_reference(reference)
        return nil if id.nil?

        index[id] || read_medication(id)
      end

      # Relative Medication/<id> or exactly base_url/Medication/<id>.
      # Foreign absolutes and malformed references do not resolve.
      def medication_id_from_reference(reference)
        prefix = medication_reference_prefix(reference)
        return nil unless prefix

        id = reference.delete_prefix(prefix)
        id if medication_id_token?(id)
      end

      def medication_reference_prefix(reference)
        return nil unless reference.is_a?(String)

        absolute = "#{@base_url}/Medication/"
        return absolute if reference.start_with?(absolute)
        return "Medication/" if reference.start_with?("Medication/")

        nil
      end

      def medication_id_token?(id)
        id.present? && !id.include?("/") && !id.include?("?") && !id.include?("#")
      end

      def read_medication(id)
        resource = fhir_read("Medication", id)
        resource if medication_resource?(resource, id)
      end

      def medication_resource?(resource, id)
        resource.is_a?(Hash) && resource["resourceType"] == "Medication" && resource["id"] == id
      end

      def authored_on_for(request)
        raw = optional_string(request["authoredOn"])
        return raw if raw.nil? || raw == :unknown

        strict_date(raw)
      end

      def dosage_text_for(request)
        instructions = request["dosageInstruction"]
        return nil if instructions.nil?
        return :unknown unless instructions.is_a?(Array) && instructions.all? { |item| item.is_a?(Hash) }
        return nil if instructions.empty?

        optional_string(instructions.first["text"])
      end
    end
  end
end
