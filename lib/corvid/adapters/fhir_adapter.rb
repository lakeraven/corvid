# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "date"
require "bigdecimal"
require "openssl"
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

      # US Core Condition.category
      # (http://terminology.hl7.org/CodeSystem/condition-category).
      CONDITION_CATEGORY_SYSTEM = "http://terminology.hl7.org/CodeSystem/condition-category"
      US_CORE_CONDITION_CATEGORIES = %w[problem-list-item encounter-diagnosis].freeze
      INCLUDED_CLINICAL_STATUSES = %w[active resolved].freeze
      BLOCKING_OUTCOME_SEVERITIES = %w[error fatal].freeze

      # Maps Corvid resource types to FHIR Coverage.type codes (HL7 v3 ActCode).
      # Real servers vary; align with deployment ValueSet.

      # A search that cannot be trusted is unknown (nil), never a partial list.
      # ArgumentError covers Date::Error while mapping an unparseable date.
      CLINICAL_READ_ERRORS = [
        Timeout::Error,
        SocketError,
        SystemCallError,
        OpenSSL::SSL::SSLError,
        IOError,
        Net::ProtocolError,
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

      # One Condition search page (no Bundle.link follow). Array of
      # ConditionReference, or nil when the page is unknown. [] means none.
      # US Core problem-list-item and encounter-diagnosis, active or resolved.
      # In memory only — never persisted or logged (ADR 0003).
      def get_conditions(patient_identifier)
        clinical_search("Condition", patient_identifier) do |bundle|
          map_condition_entries(bundle, patient_identifier)
        end
      end

      # One MedicationRequest search page. Resolves contained or bundle-included
      # Medication resources. Array of MedicationReference, or nil when unknown.
      # In memory only — never persisted or logged (ADR 0003).
      def get_medications(patient_identifier)
        clinical_search("MedicationRequest", patient_identifier) do |bundle|
          map_medication_entries(bundle, patient_identifier)
        end
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

      # Clinical search -------------------------------------------------------
      # One page. nil means unknown; never a partial list. Response bodies are
      # not logged (ADR 0003).

      def clinical_search(resource_type, patient_identifier)
        response = http_get(clinical_search_url(resource_type, patient_identifier))
        bundle = parse_search_bundle(response)
        return nil if bundle.nil?

        yield bundle
      rescue *CLINICAL_READ_ERRORS
        nil
      end

      def clinical_search_url(resource_type, patient_identifier)
        query = URI.encode_www_form(patient: patient_identifier)
        "#{@base_url}/#{resource_type}?#{query}"
      end

      def parse_search_bundle(response)
        body = clinical_response_body(response)
        return nil if body.nil?

        parsed = JSON.parse(body)
        parsed if search_bundle?(parsed)
      rescue JSON::ParserError
        nil
      end

      def clinical_response_body(response)
        return nil unless response.is_a?(Net::HTTPSuccess)

        utf8_body(response.body)
      end

      def utf8_body(body)
        return nil unless body.is_a?(String)

        utf8 = body.dup.force_encoding(Encoding::UTF_8)
        utf8 if utf8.valid_encoding?
      end

      def search_bundle?(parsed)
        parsed.is_a?(Hash) && parsed["resourceType"] == "Bundle"
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

      def strict_date(value)
        Date.parse(value)
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

        segments = reference.split("/")
        segments[-2] == "Patient" && segments[-1] == patient_identifier.to_s
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

        map_condition_resource(resource, patient_identifier)
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

        category = us_core_category(resource)
        status = clinical_status_code(resource)
        parts = codeable_parts(resource["code"])
        onset = onset_date_for(resource)
        return :unknown if unknown_value?(category, status, parts, onset)
        return nil unless include_condition?(category, status)

        condition_reference(parts, status, category, onset)
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

      def us_core_category(resource)
        categories = resource["category"]
        return nil if categories.nil?
        return :unknown unless categories.is_a?(Array)

        match = nil
        categories.each do |category|
          code = category_match(category)
          return :unknown if code == :unknown

          match ||= code
        end
        match
      end

      def category_match(category)
        return :unknown unless category.is_a?(Hash)

        codings = category["coding"]
        return nil if codings.nil?
        return :unknown unless codings.is_a?(Array)

        match = nil
        codings.each do |coding|
          code = matching_category_code(coding)
          return :unknown if code == :unknown

          match ||= code
        end
        match
      end

      def matching_category_code(coding)
        return :unknown unless coding.is_a?(Hash)
        return nil unless coding["system"] == CONDITION_CATEGORY_SYSTEM

        code = optional_string(coding["code"])
        return :unknown if code == :unknown
        return nil unless US_CORE_CONDITION_CATEGORIES.include?(code)

        code
      end

      def clinical_status_code(resource)
        codings = status_codings(resource["clinicalStatus"])
        return codings if codings.nil? || codings == :unknown
        return nil if codings.empty?

        optional_string(codings.first["code"])
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

      def codeable_parts(codeable)
        return [ nil, nil, nil ] if codeable.nil?
        return :unknown unless codeable.is_a?(Hash)

        coding = first_coding(codeable["coding"])
        return :unknown if coding == :unknown

        assemble_codeable(coding, codeable["text"])
      end

      def assemble_codeable(coding, text)
        coding ||= {}
        code = optional_string(coding["code"])
        system = optional_string(coding["system"])
        display = optional_string(coding["display"])
        fallback = optional_string(text)
        return :unknown if unknown_value?(code, system, display, fallback)

        [ code, system, display || fallback ]
      end

      def first_coding(codings)
        return nil if codings.nil?
        return :unknown unless codings.is_a?(Array)
        return nil if codings.empty?
        return :unknown unless codings.all? { |coding| coding.is_a?(Hash) }

        codings.first
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

        case resource["resourceType"]
        when "OperationOutcome"
          blocking_outcome?(resource) ? :unknown : nil
        when "Medication"
          index_medication(index, resource)
        when "MedicationRequest"
          resource
        else
          :unknown
        end
      end

      def index_medication(index, resource)
        id = resource["id"]
        return :unknown unless id.is_a?(String) && id.present?

        index[id] ||= resource
        nil
      end

      def medication_references(requests, patient_identifier, index)
        requests.each_with_object([]) do |request, results|
          mapped = build_medication_reference(request, patient_identifier, index)
          return nil if mapped.nil?

          results << mapped
        end
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
        value = request["medicationCodeableConcept"]
        request.key?("medicationCodeableConcept") && !value.nil?
      end

      def referenced_code_parts(request, index)
        medication = resolve_medication(request, index)
        return nil if medication.nil? || medication == :unknown

        parts = codeable_parts(medication["code"])
        return nil if parts == :unknown

        parts
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
        contained = request["contained"]
        return nil if contained.nil?
        return :unknown unless contained.is_a?(Array)
        return :unknown if contained.any? { |resource| !resource.is_a?(Hash) }

        contained.find { |resource| medication_id?(resource, id) }
      end

      def medication_id?(resource, id)
        resource["resourceType"] == "Medication" && resource["id"] == id
      end

      def bundled_medication(index, reference)
        segments = reference.split("?").first.split("/")
        return nil unless segments[-2] == "Medication"

        index[segments[-1]]
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
