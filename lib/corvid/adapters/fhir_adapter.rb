# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
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
      # These issue codes make the page unknown at any severity. Other codes
      # still follow BLOCKING_OUTCOME_SEVERITIES.
      UNTRUSTED_OUTCOME_CODES = %w[suppressed incomplete too-costly].freeze
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
      # get_coverages follows at most this many Bundle pages, then fails closed.
      MAX_COVERAGE_PAGES = 50
      # Only the exact Bundle.link relation "next" is followed. A relation
      # that equals "next" after removing [[:space:]] or case-folding, but
      # is not exactly "next", fails the search and is not requested.
      COVERAGE_NEXT_RELATIONS = %w[next].freeze

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

      def initialize(base_url:, bearer_token: nil, headers: {},
                     open_timeout: DEFAULT_OPEN_TIMEOUT,
                     read_timeout: DEFAULT_READ_TIMEOUT,
                     proxy_uri: nil,
                     ca_file: nil,
                     ca_path: nil)
        @base_url = base_url.chomp("/")
        @bearer_token = bearer_token
        @default_headers = {
          "Accept" => "application/fhir+json",
          "Content-Type" => "application/fhir+json"
        }.merge(headers)
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @proxy_uri = build_proxy_uri(proxy_uri)
        @ca_file = ca_file
        @ca_path = ca_path
      end

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

      def search_patients(query)
        bundle = fhir_search("Patient", name: query)
        extract_entries(bundle).map { |r| build_patient_reference(r) }
      end

      # ----------------------------------------------------------------------
      # Practitioner
      # ----------------------------------------------------------------------

      def find_practitioner(practitioner_identifier)
        resource = fhir_read("Practitioner", practitioner_identifier)
        return nil unless resource

        build_practitioner_reference(resource)
      end

      def search_practitioners(query)
        bundle = fhir_search("Practitioner", name: query)
        extract_entries(bundle).map { |r| build_practitioner_reference(r) }
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
        true
      end

      def list_referrals(patient_identifier)
        bundle = fhir_search("ServiceRequest", patient: patient_identifier)
        extract_entries(bundle).map { |r| build_referral_reference(r) }
      end

      # ----------------------------------------------------------------------
      # Claims — purchased/referred-care billed line items
      #
      # Reads stock FHIR R4 `Claim` resources (`Claim?patient=<id>`) and
      # flattens each `Claim.item` into a Corvid::ClaimLineReference. Uses
      # only standard R4 elements — patient, provider, item.productOrService
      # (CPT/HCPCS coding), item.servicedDate/servicedPeriod, item.net — so
      # any conformant FHIR server (regardless of source EHR) maps the same
      # way. No vendor-specific extensions.
      # ----------------------------------------------------------------------

      def list_claims(patient_identifier)
        bundle = fhir_search("Claim", patient: patient_identifier)
        extract_entries(bundle).flat_map { |claim| build_claim_line_references(claim) }
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
      # even when clinical status is unusable. Never raises.
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
      # Medication ids are not requested. Never raises. Array of
      # MedicationReference, or nil when unknown. In memory only — never
      # persisted or logged (ADR 0003).
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

      def get_care_team(patient_identifier)
        bundle = fhir_search("CareTeam", patient: patient_identifier)
        extract_entries(bundle).flat_map do |resource|
          (resource["participant"] || []).map do |p|
            Corvid::CareTeamMemberReference.new(
              practitioner_identifier: p.dig("member", "reference")&.sub("Practitioner/", ""),
              role: p.dig("role", 0, "coding", 0, "code"),
              name: resource["name"],
              status: resource["status"]
            )
          end
        end
      end

      # ----------------------------------------------------------------------
      # Coverages
      #
      # GET Coverage?beneficiary=Patient/<id>. A nil, empty, or
      # whitespace-only patient identifier is nil and makes no request.
      # Bundle.type must equal "searchset" or the search is nil. Follow
      # Bundle.link relation "next" for up to MAX_COVERAGE_PAGES pages.
      # Only that exact relation is followed. When link is present it
      # must be an Array of Hashes, each with a String relation. An
      # exactly-"next" link must have a String url. A relation that
      # equals "next" after removing Unicode whitespace ([[:space:]])
      # or case-folding, but is not exactly "next", is nil and is not
      # requested. A non-String relation, or more than one "next" link,
      # is nil. A relative next URL is resolved with
      # URI.join against the URL of the page that contained it. That
      # absolute URL is fetched only when it stays on this origin and
      # under the base path.
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
      # equal to "selfpay" is self-pay when there is no coding. When kind
      # is present it must be "insurance". Coverages excluded by this
      # allowlist still count toward the total check.
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
      # payor[0].display, subscriberId, and type.coding[0].code, when
      # present but not a String, make the search nil. Integer 9 on the
      # X12 claim-filing-indicator system remains self-pay.
      # Every Coverage resource is counted across all pages before the
      # active and insurance filters. When a page includes total, it must
      # be an Integer >= 0 and equal to the first page's total; a later
      # page may omit total. The first page's total must equal that count,
      # or the result is nil. An OperationOutcome entry is nil when issue
      # is missing, not an Array, empty, contains a non-Hash, or has a
      # severity other than exactly "fatal", "error", "warning", or
      # "information". An issue code present but not a String is nil.
      # Codes suppressed, incomplete, and too-costly
      # (UNTRUSTED_OUTCOME_CODES) are nil at any severity. "error" and
      # "fatal" still block. A well-formed warning or information issue
      # with another String code is ignored. A resourceType equal to
      # "OperationOutcome" case-insensitively or after stripping, but
      # not exactly, is nil. A page with no entry and total nil
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
      # missing or duplicate Coverage id, an untrusted beneficiary or
      # period, a malformed Coverage, a status outside the FHIR set, a
      # total that is not an Integer >= 0, differs from the first page,
      # or does not match the Coverage count, invalid encoding, an
      # untrusted or inexact OperationOutcome, an empty issue array, a
      # non-String issue code, an unexpected resource without
      # search.mode "include", a blank patient identifier, a non-String
      # payor display, subscriberId, or type code, an off-origin /
      # cyclic / over-limit next link, or a next relation that matches
      # only after removing [[:space:]] or case-folding,
      # or a transport error
      # (Timeout::Error, including Net::ReadTimeout and Net::OpenTimeout,
      # SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError,
      # Net::ProtocolError, Net::HTTPBadResponse,
      # Net::HTTPHeaderSyntaxError, Zlib::Error).
      # Callers fail closed; a partial page list is never returned.
      # ----------------------------------------------------------------------

      def get_coverages(patient_identifier)
        return nil if patient_identifier.blank?

        query = URI.encode_www_form(beneficiary: "Patient/#{patient_identifier}")
        collect_coverage_pages("#{@base_url}/Coverage?#{query}", patient_identifier)
      rescue Timeout::Error, SocketError, SystemCallError,
             OpenSSL::SSL::SSLError, IOError, Net::ProtocolError,
             Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Zlib::Error
        nil
      end

      # ----------------------------------------------------------------------
      # Eligibility
      # ----------------------------------------------------------------------

      def verify_eligibility(patient_identifier, resource_type)
        bundle = fhir_search("Coverage", beneficiary: "Patient/#{patient_identifier}")
        coverages = extract_entries(bundle)

        coverage = if resource_type.to_s != ""
          fhir_code = COVERAGE_TYPE_MAP[resource_type.to_s]
          coverages.find do |c|
            type_code = c.dig("type", "coding", 0, "code")
            type_code == fhir_code || type_code == resource_type.to_s
          end
        end
        coverage ||= coverages.first
        return nil unless coverage

        {
          eligible: coverage["status"] == "active",
          payer_name: coverage.dig("payor", 0, "display"),
          policy_number: coverage["subscriberId"],
          coverage_start: parse_date(coverage.dig("period", "start")),
          coverage_end: parse_date(coverage.dig("period", "end"))
        }
      end

      # ----------------------------------------------------------------------
      # Enrollment verification — FHIR R4 / US Core have no native tribal
      # enrollment concept, so this reads Lakeraven's tribal-enrollment
      # extension on Patient (see TRIBAL_ENROLLMENT_EXTENSION_URL below).
      # Servers that don't populate the extension fall back to
      # "unavailable" (fail-closed) exactly as before — this is additive,
      # not a behavior change for plain-vanilla FHIR servers.
      # ----------------------------------------------------------------------

      TRIBAL_ENROLLMENT_EXTENSION_URL = "#{EXTENSION_BASE_URL}/tribal-enrollment"
      RESIDENCY_EXTENSION_URL = "#{EXTENSION_BASE_URL}/residency"
      US_CORE_BIRTHPLACE_URL = "http://hl7.org/fhir/us/core/StructureDefinition/us-core-birthplace"

      def verify_tribal_enrollment(patient_identifier)
        unavailable = {
          enrolled: false, membership_number: nil, tribe_name: nil, tribe_code: nil,
          confidence: :unavailable, verified_at: Time.current
        }

        patient = fhir_read("Patient", patient_identifier)
        return unavailable unless patient

        ext = find_extension(patient, TRIBAL_ENROLLMENT_EXTENSION_URL)
        return unavailable unless ext

        {
          enrolled: sub_extension_value(ext, "enrolled") == true,
          membership_number: sub_extension_value(ext, "membershipNumber"),
          tribe_name: sub_extension_value(ext, "tribeName"),
          tribe_code: sub_extension_value(ext, "tribeCode"),
          confidence: (sub_extension_value(ext, "confidence") || "verified").to_sym,
          verified_at: Time.current
        }
      end

      def verify_identity_documents(patient_identifier)
        empty = { ssn_present: false, dob_present: false, birthplace_present: false, verified_at: Time.current }

        patient = fhir_read("Patient", patient_identifier)
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

        patient = fhir_read("Patient", patient_identifier)
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

      def check_claim_status(_claim_identifier)
        { status: "unsupported" }
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

      private

      # FHIR REST primitives ------------------------------------------------

      def fhir_read(resource_type, id)
        return nil if unreadable_medication_id?(resource_type, id)

        response = http_get("#{@base_url}/#{resource_type}/#{id}")
        parse_success_json(response)
      end

      def fhir_search(resource_type, params = {})
        query_string = URI.encode_www_form(params)
        response = http_get("#{@base_url}/#{resource_type}?#{query_string}")
        parse_success_json(response)
      end

      # 204 and an empty body are not a resource. Parsing nil raises, and
      # that message must not escape with a URL or payload.
      def parse_success_json(response)
        return nil unless response.is_a?(Net::HTTPSuccess)
        return nil if empty_response?(response)

        JSON.parse(response.body)
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
        request["Authorization"] = "Bearer #{@bearer_token}" if @bearer_token

        build_http(uri).request(request)
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
        [ nil, "unparseable billed amount #{value.inspect}" ]
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
          service_requested: resource.dig("code", "text").presence || resource.dig("code", "coding", 0, "display").presence,
          requesting_provider_identifier: resource.dig("requester", "reference")&.split("/")&.last
        )
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

      def extract_entries(bundle)
        return [] unless bundle.is_a?(Hash) && bundle["entry"].is_a?(Array)

        bundle["entry"].filter_map { |e| e["resource"] }
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

      def find_extension(resource, url)
        Array(resource["extension"]).find { |e| e["url"] == url }
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

      # Coverage search -----------------------------------------------------

      def collect_coverage_pages(url, patient_identifier)
        found, seen, seen_ids = [], {}, {}
        received = 0
        stated_total = nil

        MAX_COVERAGE_PAGES.times do |index|
          page = read_coverage_page(url, seen, seen_ids, patient_identifier)
          return nil unless page

          stated_total = page[:stated_total] if index.zero?
          return nil unless coverage_page_total_ok?(page[:stated_total], stated_total)

          received += page[:coverage_count]
          found.concat(page[:coverages])
          url = page[:next_url]
          return coverage_search_result(found, received, stated_total) if url.nil?
        end
        nil
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

      def read_coverage_page(url, seen, seen_ids, patient_identifier)
        absolute = absolute_coverage_url(url)
        return nil if absolute.nil? || seen[absolute] || !same_origin_coverage_url?(absolute)

        seen[absolute] = true
        fetch_coverage_bundle(absolute, patient_identifier, seen_ids)
      end

      # Absolute references pass through. Relative next links are resolved
      # against the page that contained them before they reach this method.
      def absolute_coverage_url(url)
        return nil unless url.is_a?(String) && !url.empty?

        URI.join(@base_url, url).to_s
      rescue URI::InvalidURIError, URI::InvalidComponentError, URI::BadURIError
        nil
      end

      def fetch_coverage_bundle(url, patient_identifier, seen_ids)
        response = http_get(url)
        return nil unless response.is_a?(Net::HTTPSuccess)

        bundle = parse_coverage_bundle(response.body)
        return nil unless bundle

        page = active_coverage_rows(bundle, patient_identifier, seen_ids)
        return nil unless page

        next_url = coverage_next_url(url, bundle)
        return nil if next_url == :invalid_coverage_next

        page.merge(next_url: next_url, stated_total: bundle["total"])
      end

      # URI.join against the page URL, then the next read applies the
      # same-origin and base-path checks before fetching.
      def coverage_next_url(page_url, bundle)
        link = bundle_next_url(bundle)
        return link if link.nil? || link == :invalid_coverage_next

        URI.join(page_url, link).to_s
      rescue URI::InvalidURIError, URI::InvalidComponentError, URI::BadURIError
        :invalid_coverage_next
      end

      def parse_coverage_bundle(body)
        return nil unless body.is_a?(String) && body.valid_encoding?

        parsed = JSON.parse(body)
        return nil unless parsed.is_a?(Hash) && parsed["resourceType"] == "Bundle"
        return nil unless parsed["type"] == "searchset"
        return nil unless coverage_strings_encoded?(parsed)

        parsed
      rescue JSON::ParserError, ArgumentError, EncodingError
        nil
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
      # a non-String code, or a severity outside COVERAGE_OUTCOME_SEVERITIES
      # is unknown. error and fatal still block. UNTRUSTED_OUTCOME_CODES
      # block at any severity. A well-formed warning or information issue
      # with another String code does not.
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
        return true if non_string_issue_code?(issue["code"])

        untrusted_outcome?(issue) || BLOCKING_OUTCOME_SEVERITIES.include?(issue["severity"])
      end

      def non_string_issue_code?(code)
        !code.nil? && !code.is_a?(String)
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
          trusted_primary_type_code?(resource)
      end

      def coverage_string_or_nil?(value)
        value.nil? || value.is_a?(String)
      end

      # nil and String are copied onto the row. Integer 9 on the X12
      # claim-filing system is the self-pay code. Any other value is unknown.
      def trusted_primary_type_code?(resource)
        code = coverage_primary_type_code(resource)
        return true if coverage_string_or_nil?(code)

        coding = coverage_primary_coding(resource)
        coding.is_a?(Hash) && x12_self_pay?(code, coding["system"])
      end

      def coverage_primary_coding(resource)
        codings = coverage_type_codings(resource)
        return nil unless codings.is_a?(Array)

        codings.first
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
        return false unless coverage_kind_allows?(resource)
        return false unless organization_payors?(payors)
        return false if self_pay_type_text?(resource, codings)

        codings.all? { |coding| insurance_type_coding?(coding) }
      end

      def coverage_kind_allows?(resource)
        !resource.key?("kind") || resource["kind"] == "insurance"
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

        bundle = fhir_search(resource_type, patient: patient_identifier)
        return nil unless search_bundle?(bundle)
        return nil if next_page_link?(bundle)
        return nil unless consistent_search_total?(bundle, resource_type)

        yield bundle
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
        return false unless entry.is_a?(Hash)

        search = entry["search"]
        return true if search.nil?
        return false unless search.is_a?(Hash)

        mode = search["mode"]
        mode.nil? || mode == "match"
      end

      def bundle_entries(bundle)
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

      def blocking_issue?(issue)
        return true unless issue.is_a?(Hash)

        untrusted_outcome?(issue) || blocking_severity?(issue)
      end

      def untrusted_outcome?(issue)
        code = issue["code"]
        code.is_a?(String) && UNTRUSTED_OUTCOME_CODES.include?(code)
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

      def bundle_next_url(bundle)
        links = bundle["link"]
        return nil if links.nil?
        return :invalid_coverage_next unless links.is_a?(Array)

        single_coverage_next_url(links)
      end

      def single_coverage_next_url(links)
        chosen = nil
        links.each do |link|
          url = coverage_link_url(link)
          return :invalid_coverage_next if url == :invalid
          next if url.nil?
          return :invalid_coverage_next if chosen

          chosen = url
        end
        chosen
      end

      def coverage_link_url(link)
        relation = coverage_link_relation(link)
        return relation if relation.nil? || relation == :invalid

        strict_next_url(link["url"])
      end

      # :invalid fails the search. nil is a link that is not the next page.
      def coverage_link_relation(link)
        return :invalid unless link.is_a?(Hash)

        relation = link["relation"]
        return :invalid unless relation.is_a?(String)
        return :invalid if rejected_next_relation?(relation)

        relation if followed_next_relation?(relation)
      end

      def rejected_next_relation?(relation)
        folded_next_relation?(relation) && !followed_next_relation?(relation)
      end

      # Equals "next" once [[:space:]] is removed and case is folded.
      def folded_next_relation?(relation)
        relation.gsub(/[[:space:]]/, "").casecmp?("next")
      end

      def followed_next_relation?(relation)
        COVERAGE_NEXT_RELATIONS.include?(relation)
      end

      def strict_next_url(url)
        return :invalid unless url.is_a?(String) && !url.empty?

        url
      end

      def same_origin_coverage_url?(url)
        return false unless url.is_a?(String) && !url.empty?

        candidate = URI.parse(url)
        base = URI.parse(@base_url)
        return false unless candidate.is_a?(URI::HTTP) && base.is_a?(URI::HTTP)
        return false unless candidate.scheme == base.scheme && candidate.port == base.port
        return false unless candidate.host.to_s.casecmp?(base.host.to_s)

        path_under_base?(candidate.path, base.path)
      rescue URI::InvalidURIError, URI::InvalidComponentError
        false
      end

      def path_under_base?(candidate_path, base_path)
        child = normalized_coverage_path(candidate_path)
        root = normalized_coverage_path(base_path)
        return false unless child && root

        child == root || child.start_with?(root == "/" ? "/" : "#{root}/")
      end

      def normalized_coverage_path(path)
        return nil unless path.is_a?(String)

        decoded = repeated_decode(path)
        return nil unless decoded.is_a?(String)
        return nil if decoded.match?(/[[:cntrl:]\\]/)
        return nil unless decoded.empty? || decoded.start_with?("/")

        collapse_coverage_segments(decoded)
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

      def collapse_coverage_segments(decoded)
        segments = []
        decoded.split("/").each do |segment|
          next if segment.empty? || segment == "."
          return nil if segment == ".." && segments.empty?

          segment == ".." ? segments.pop : segments << segment
        end
        "/#{segments.join("/")}"
      end

      # Conditions ------------------------------------------------------------

      def map_condition_entries(bundle, patient_identifier)
        entries = bundle_entries(bundle)
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
        entries = bundle_entries(bundle)
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
