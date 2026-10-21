# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "date"
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

      # One search that still has a next page after this many Bundles is
      # undetermined. Callers never see a partial result.
      MAX_SEARCH_PAGES = 100

      # Next URL that aborts the search and is never requested.
      SEARCH_REJECTED = :rejected
      private_constant :SEARCH_REJECTED

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
        extract_entries(bundle)
          .select { |resource| resource["resourceType"] == "Patient" }
          .map { |resource| build_patient_reference(resource) }
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
          coverage_start: parse_period_date(coverage.dig("period", "start"), :start),
          coverage_end: parse_period_date(coverage.dig("period", "end"), :end)
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
          confidence: (sub_extension_value(ext, "confidence") || "unavailable").to_sym,
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

      # Returns one Bundle whose `entry` array is every page, in order.
      # Follows `link` entries with relation exactly "next", resolving each
      # URL with URI.join against the current page. Fail closed: returns nil
      # (never a partial Bundle) when any page is non-2xx, invalid JSON, an
      # empty or nil body, a String body that is not valid_encoding?, or not
      # a Bundle Hash; when `entry` is present and not an Array (absent or
      # null is an empty page); when `link` is present and not an Array;
      # when a link relation or url String is not valid_encoding?; when a
      # Hash link's relation is a String equal to "next" only after strip
      # and case-insensitive compare (that URL is not requested); when more
      # than one exactly-"next" link is present (neither URL is requested);
      # when parsing, joining, or checking a next URL raises URI::Error;
      # when a next URL's scheme or port differs from @base_url, or its host
      # differs case-insensitively; when its path does not start with
      # @base_url's path at a segment boundary; when that path contains ";",
      # a backslash, or an encoded %2f/%5c/%3b/%25 (any case) before or
      # after percent-decoding, or a path segment is "." or ".." after
      # %2e/%2E are decoded (that URL is not requested); when a present
      # `total` is not a non-negative Integer, or differs from the count of
      # merged entries whose search.mode is "match" or absent (an equal
      # total is kept, an absent total stays absent, and outcome and include
      # entries are not counted); when the same resourceType and id appear
      # twice among those match or no-mode entries (repeated include entries
      # are allowed); when a next URL was already visited; or when the chain
      # is longer than MAX_SEARCH_PAGES.
      def fhir_search(resource_type, params = {})
        query = URI.encode_www_form(params)
        pages = collect_search_pages("#{@base_url}/#{resource_type}?#{query}")
        merge_search_pages(pages) if pages
      end

      # 204 and an empty body are not a resource. Parsing nil raises, and
      # that message must not escape with a URL or payload.
      def parse_success_json(response)
        return nil unless response.is_a?(Net::HTTPSuccess)
        return nil if empty_response?(response)

        JSON.parse(response.body)
      end

      def collect_search_pages(url)
        pages = []
        seen = {}

        while url && pages.size < MAX_SEARCH_PAGES && !seen[url]
          page = fetch_bundle_page(url)
          return unless page && acceptable_entries?(page)

          seen[url] = true
          pages << page
          url = next_search_url(page, url)
          return if url == SEARCH_REJECTED
        end

        # A nil url means the chain ended. A leftover url is a page cap or a
        # repeated next link, so pages already read are discarded.
        pages if url.nil?
      end

      def fetch_bundle_page(url)
        response = http_get(url)
        return unless response.is_a?(Net::HTTPSuccess)

        parse_search_bundle(response.body)
      end

      def parse_search_bundle(body)
        return if !body.is_a?(String) || body.empty? || !body.valid_encoding?

        bundle = JSON.parse(body)
        bundle if bundle.is_a?(Hash) && bundle["resourceType"] == "Bundle"
      rescue JSON::ParserError, TypeError
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
        return SEARCH_REJECTED if links.any? { |link| invalid_link_encoding?(link) }
        return SEARCH_REJECTED if links.any? { |link| inexact_next_relation?(link) }

        next_links = links.select { |link| next_relation?(link) }
        return SEARCH_REJECTED if next_links.size > 1
        return if next_links.empty?

        href = next_links.first["url"]
        href.is_a?(String) && href.valid_encoding? && !href.empty? ? href : SEARCH_REJECTED
      end

      def invalid_link_encoding?(link)
        return false unless link.is_a?(Hash)

        [ link["relation"], link["url"] ].any? { |value| value.is_a?(String) && !value.valid_encoding? }
      end

      def inexact_next_relation?(link)
        return false unless link.is_a?(Hash)

        relation = link["relation"]
        return false unless relation.is_a?(String) && relation != "next"

        relation.strip.casecmp?("next")
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
        base = base_path.to_s.chomp("/")
        base = "/" if base.empty?
        other = other_path.to_s
        other = "/" if other.empty?
        base == "/" || other == base || other.start_with?("#{base}/")
      end

      # "." and ".." segments, including %2e/%2E, are rejected before fetch.
      # ";", a backslash, encoded separators %2f/%5c, an encoded ";" (%3b)
      # and any double-encoded escape (%25), all in any case, are rejected
      # on the path both before and after that percent-decoding. A gateway
      # that decodes, strips path parameters and normalizes dot segments
      # could otherwise route the request outside the base path.
      def dot_segment_path?(href)
        raw = URI.parse(href).path.to_s
        decoded = raw.gsub(/%2e/i, ".")
        return true if forbidden_next_path?(raw) || forbidden_next_path?(decoded)

        decoded.split("/").any? { |segment| segment == "." || segment == ".." }
      rescue URI::Error
        false
      end

      def forbidden_next_path?(path)
        path.match?(/[;\\]|%2f|%5c|%3b|%25/i)
      end

      def merge_search_pages(pages)
        entries = pages.flat_map { |page| bundle_entries(page) }
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

      def acceptable_entries?(page)
        return true unless page.key?("entry")

        entry = page["entry"]
        entry.nil? || entry.is_a?(Array)
      end

      def bundle_entries(page)
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
