# frozen_string_literal: true

require "corvid/adapters/fhir_adapter"

module Corvid
  module Adapters
    # Offline stock-FHIR adapter for demos and tests.
    #
    # It IS the generic FhirAdapter — every read goes through the real
    # FhirAdapter FHIR-R4 parsing code (find_patient, verify_eligibility,
    # verify_tribal_enrollment, list_claims, get_coverages, ...). The HTTP
    # transport is what changes: `fhir_read` and `fhir_search` serve
    # resources from an in-memory FHIR store, and `fetch_bundle_page`
    # serves each search page from that store. Page walks such as
    # get_coverages therefore apply the same Coverage rules without
    # net/http. `fhir_search` itself still returns one in-memory Bundle.
    # That keeps the demo self-contained (no live FHIR server) while
    # proving the exact same stock-FHIR code path a production deployment
    # runs against any conformant FHIR R4 server.
    #
    # The store is a plain array of FHIR resource hashes (as a real server
    # would return them). No vendor-specific shapes — see
    # Corvid::Demo::FhirOverlayData for the synthetic dataset.
    class FhirDemoAdapter < FhirAdapter
      # resources: Array<Hash> of FHIR R4 resource hashes.
      def initialize(resources: [])
        super(base_url: "memory://fhir-demo")
        @by_type_and_id = Hash.new { |h, k| h[k] = {} }
        @by_type = Hash.new { |h, k| h[k] = [] }
        Array(resources).each { |r| add_resource(r) }
      end

      def add_resource(resource)
        type = resource["resourceType"] || resource[:resourceType]
        resource = deep_stringify(resource)
        @by_type[type] << resource
        id = resource["id"]
        @by_type_and_id[type][id] = resource if id
        resource
      end

      private

      # --- Overridden REST transport: serve from memory, no HTTP ----------

      def fhir_read(resource_type, id)
        @by_type_and_id[resource_type][id.to_s]
      end

      # Minimal in-memory search. Supports the search params the overlay
      # ingest uses: Patient?name=, Claim?patient=, Coverage?beneficiary=,
      # ServiceRequest?patient=, CareTeam?patient=. Matching mirrors how a
      # real FHIR server resolves these references/tokens.
      def fhir_search(resource_type, params = {})
        memory_search_bundle(resource_type, params)
      end

      # Same Bundle #fhir_search builds, so a page walk stays in memory and
      # still runs the caller's Coverage rules. Does not follow next links;
      # the store is one page.
      def fetch_bundle_page(url)
        uri = URI.parse(url.to_s)
        resource_type = uri.path.to_s.split("/").reject(&:empty?).first
        return if resource_type.nil?

        memory_search_bundle(resource_type, URI.decode_www_form(uri.query.to_s).to_h)
      rescue URI::Error, ArgumentError
        nil
      end

      def memory_search_bundle(resource_type, params)
        params = params.transform_keys(&:to_s)
        matches = @by_type[resource_type].select { |r| search_match?(resource_type, r, params) }
        {
          "resourceType" => "Bundle",
          "type" => "searchset",
          "total" => matches.size,
          "entry" => matches.map { |r| { "resource" => r } }
        }
      end

      def search_match?(resource_type, resource, params)
        params.all? do |key, value|
          case key
          when "patient", "beneficiary", "subject"
            reference_matches?(resource, value)
          when "name"
            name_matches?(resource, value)
          else
            true
          end
        end
      end

      def reference_matches?(resource, value)
        wanted = patient_reference_token(value)
        patient_reference_values(resource).include?(wanted)
      end

      def patient_reference_values(resource)
        [
          resource.dig("patient", "reference"),
          resource.dig("beneficiary", "reference"),
          resource.dig("subject", "reference")
        ].compact.map { |ref| patient_reference_token(ref) }
      end

      # Patient/<id> and <base_url>/Patient/<id> both name this server's
      # patient. Any other reference is left intact so a foreign absolute
      # URL cannot match a local id.
      def patient_reference_token(reference)
        ref = reference.to_s
        return ref.delete_prefix("Patient/") if ref.start_with?("Patient/")

        absolute = "#{@base_url}/Patient/"
        return ref.delete_prefix(absolute) if ref.start_with?(absolute)

        ref
      end

      def name_matches?(resource, value)
        needle = value.to_s.downcase
        Array(resource["name"]).any? do |n|
          [ n["family"], *Array(n["given"]) ].compact.any? { |part| part.downcase.include?(needle) }
        end
      end

      def deep_stringify(obj)
        case obj
        when Hash then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
        when Array then obj.map { |v| deep_stringify(v) }
        else obj
        end
      end
    end
  end
end
