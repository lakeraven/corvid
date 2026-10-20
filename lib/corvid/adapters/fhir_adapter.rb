# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "date"
require "time"
require "zlib"
require "bigdecimal"
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

      # Maps Corvid resource types to FHIR Coverage.type codes (HL7 v3 ActCode).
      # Real servers vary; align with deployment ValueSet.
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
      # GET Coverage?beneficiary=Patient/<id>, then follow Bundle.link
      # relation "next" (any case) for up to MAX_COVERAGE_PAGES pages on
      # this origin. A relative next URL is resolved with URI.join against
      # base_url before the same-origin and path checks; that absolute URL
      # is what gets fetched.
      #
      # Every Coverage entry must name this patient: beneficiary.reference
      # equals "Patient/<id>" or ends with "/Patient/<id>". A Coverage with
      # a different or missing beneficiary means the server ignored the
      # filter, so the whole result is nil.
      #
      # Returns active coverages whose period covers now. A missing start or
      # end is an open bound. FHIR precision: "YYYY" is Jan 1 (start) or
      # Dec 31 (end); "YYYY-MM" is the first or last day of that month;
      # "YYYY-MM-DD" is that date against Date.current. A dateTime (value
      # contains "T") is an instant — Time.iso8601, otherwise DateTime —
      # compared with Time.current (start <= now, end >= now). A present
      # but unparseable bound makes the whole result nil, not a dropped row.
      #
      # A Bundle with no entry is [] only when total is absent or 0; total
      # greater than 0 with no entries is nil. plan_name is the class entry
      # typed "plan": its name, otherwise its value.
      #
      # An Array means the search finished ([] when nothing matched). nil
      # means unknown — a non-2xx page, bad JSON, a non-Bundle body, an
      # untrusted beneficiary or period, a positive total with no entries,
      # an off-origin / cyclic / over-limit next link, or a transport error
      # (Timeout::Error, including Net::ReadTimeout and Net::OpenTimeout,
      # SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError,
      # Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Zlib::Error).
      # Callers fail closed; a partial page list is never returned.
      # ----------------------------------------------------------------------

      def get_coverages(patient_identifier)
        query = URI.encode_www_form(beneficiary: "Patient/#{patient_identifier}")
        collect_coverage_pages("#{@base_url}/Coverage?#{query}", patient_identifier)
      rescue Timeout::Error, SocketError, SystemCallError,
             OpenSSL::SSL::SSLError, IOError, Net::HTTPBadResponse,
             Net::HTTPHeaderSyntaxError, Zlib::Error
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
        response = http_get("#{@base_url}/#{resource_type}/#{id}")
        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      end

      def fhir_search(resource_type, params = {})
        query_string = URI.encode_www_form(params)
        response = http_get("#{@base_url}/#{resource_type}?#{query_string}")
        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
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
        found = []
        seen = {}

        MAX_COVERAGE_PAGES.times do
          page = read_coverage_page(url, seen, patient_identifier)
          return nil unless page

          found.concat(page[:coverages])
          url = page[:next_url]
          return found if url.nil?
        end
        nil
      end

      def read_coverage_page(url, seen, patient_identifier)
        absolute = absolute_coverage_url(url)
        return nil if absolute.nil? || seen[absolute] || !same_origin_coverage_url?(absolute)

        seen[absolute] = true
        fetch_coverage_bundle(absolute, patient_identifier)
      end

      # Relative next links are resolved against base_url before the
      # same-origin check. An absolute link is unchanged when it is already
      # a valid URI.
      def absolute_coverage_url(url)
        return nil unless url.is_a?(String) && !url.empty?

        URI.join(@base_url, url).to_s
      rescue URI::InvalidURIError, URI::InvalidComponentError, URI::BadURIError
        nil
      end

      def fetch_coverage_bundle(url, patient_identifier)
        response = http_get(url)
        return nil unless response.is_a?(Net::HTTPSuccess)

        bundle = parse_coverage_bundle(response.body)
        return nil unless bundle

        rows = active_coverage_rows(bundle, patient_identifier)
        return nil if rows.nil?

        next_url = bundle_next_url(bundle)
        return nil if next_url == :invalid_coverage_next

        { coverages: rows, next_url: next_url }
      end

      def parse_coverage_bundle(body)
        return nil unless body.is_a?(String)

        parsed = JSON.parse(body)
        parsed if parsed.is_a?(Hash) && parsed["resourceType"] == "Bundle"
      rescue JSON::ParserError
        nil
      end

      def active_coverage_rows(bundle, patient_identifier)
        entries = bundle["entry"]
        return coverage_page_without_entries(bundle) if entries.nil?
        return nil unless entries.is_a?(Array)

        rows = []
        entries.each do |entry|
          row = coverage_row(entry, patient_identifier)
          return nil if row == :unknown_coverage

          rows << row if row
        end
        rows
      end

      # No entry array: an omitted or zero total is an empty search. A
      # positive total with nothing inline means the page is incomplete.
      def coverage_page_without_entries(bundle)
        total = bundle["total"]
        total.nil? || total == 0 ? [] : nil
      end

      def coverage_row(entry, patient_identifier)
        resource = entry.is_a?(Hash) ? entry["resource"] : nil
        return nil unless resource.is_a?(Hash) && resource["resourceType"] == "Coverage"
        return :unknown_coverage unless coverage_beneficiary_matches?(resource, patient_identifier)
        return nil unless resource["status"] == "active"

        period_state = coverage_period_current?(resource)
        return :unknown_coverage if period_state == :unknown_coverage
        return nil unless period_state

        coverage_attributes(resource)
      end

      def coverage_beneficiary_matches?(resource, patient_identifier)
        reference = resource.dig("beneficiary", "reference")
        return false unless reference.is_a?(String)

        expected = "Patient/#{patient_identifier}"
        reference == expected || reference.end_with?("/#{expected}")
      end

      def coverage_period_current?(resource)
        period = resource["period"]
        return true if period.nil?
        return false unless period.is_a?(Hash)

        start_ok = coverage_bound_ok?(period["start"], :on_or_before)
        end_ok = coverage_bound_ok?(period["end"], :on_or_after)
        return :unknown_coverage if start_ok == :unknown_coverage || end_ok == :unknown_coverage

        start_ok && end_ok
      end

      # true / false filter the row. :unknown_coverage fails the whole search.
      def coverage_bound_ok?(raw, direction)
        return true if raw.nil? || raw == ""
        return :unknown_coverage unless raw.is_a?(String)

        point = coverage_bound_point(raw, direction)
        return :unknown_coverage unless point

        current = point.is_a?(Time) ? Time.current : Date.current
        direction == :on_or_before ? point <= current : point >= current
      end

      # Full dates go through parse_date. Year and year-month do not:
      # Ruby 4 Date.parse rejects them, and an end bound is the last day.
      def coverage_bound_point(raw, direction)
        if raw.include?("T")
          parse_coverage_instant(raw)
        elsif raw.match?(/\A\d{4}-\d{2}\z/)
          year_text, month_text = raw.split("-", 2)
          parse_month_bound(year_text, month_text, direction)
        elsif raw.match?(/\A\d{4}\z/)
          parse_date(direction == :on_or_before ? "#{raw}-01-01" : "#{raw}-12-31")
        else
          parse_date(raw)
        end
      end

      def parse_month_bound(year_text, month_text, direction)
        month = month_text.to_i
        return nil unless (1..12).cover?(month)

        year = year_text.to_i
        day = direction == :on_or_before ? 1 : Date.new(year, month, -1).day
        parse_date(format("%s-%02d-%02d", year_text, month, day))
      end

      def parse_coverage_instant(text)
        Time.iso8601(text)
      rescue ArgumentError
        parse_coverage_datetime(text)
      end

      def parse_coverage_datetime(text)
        DateTime.iso8601(text).to_time
      rescue ArgumentError
        nil
      end

      def coverage_attributes(resource)
        {
          payer_name: resource.dig("payor", 0, "display"),
          plan_name: coverage_plan_name(resource),
          coverage_type: resource.dig("type", "coding", 0, "code"),
          policy_number: resource["subscriberId"],
          coverage_start: parse_date(resource.dig("period", "start")),
          coverage_end: parse_date(resource.dig("period", "end")),
          status: resource["status"]
        }
      end

      def coverage_plan_name(resource)
        classes = resource["class"]
        return nil unless classes.is_a?(Array)

        plan = classes.find do |row|
          row.is_a?(Hash) && row.dig("type", "coding", 0, "code") == "plan"
        end
        return nil unless plan

        [ plan["name"], plan["value"] ].find { |item| item.is_a?(String) && !item.empty? }
      end

      def bundle_next_url(bundle)
        links = bundle["link"]
        return nil if links.nil?
        return :invalid_coverage_next unless links.is_a?(Array)

        link = links.find { |row| row.is_a?(Hash) && row["relation"].to_s.casecmp?("next") }
        return nil unless link

        url = link["url"]
        url.is_a?(String) && !url.empty? ? url : :invalid_coverage_next
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
    end
  end
end
