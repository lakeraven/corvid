# frozen_string_literal: true

require "securerandom"
require "corvid/adapters/fhir_adapter"

module Corvid
  module Adapters
    # Offline stock-FHIR adapter for demos and tests.
    #
    # It IS the generic FhirAdapter — every read goes through the real
    # FhirAdapter FHIR-R4 parsing code (find_patient, verify_eligibility,
    # verify_tribal_enrollment, list_claims, ...). The ONLY thing overridden
    # is the HTTP transport: instead of issuing `net/http` calls, the REST
    # primitives (`fhir_read`, `fhir_search`, `fhir_create`, `fhir_update`)
    # serve and store resources in an in-memory FHIR store. That keeps the
    # demo self-contained (no live FHIR server) while proving the exact same
    # stock-FHIR code path a production deployment runs against any
    # conformant FHIR R4 server. Writes (create_referral, update_referral)
    # land in that store, so later reads see them.
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

      # Returns a copy, as a server would: the store changes only through
      # fhir_create and fhir_update.
      def fhir_read(resource_type, id)
        resource = @by_type_and_id[resource_type][id.to_s]
        resource && deep_stringify(resource)
      end

      # The server assigns the id, as POST does on a real FHIR server.
      def fhir_create(resource_type, body)
        resource = deep_stringify(body).merge("resourceType" => resource_type, "id" => SecureRandom.uuid)
        deep_stringify(add_resource(resource))
      end

      # PUT to an id the store does not hold fails, as it would without
      # update-as-create.
      def fhir_update(resource_type, id, body)
        id = id.to_s
        return false unless @by_type_and_id[resource_type].key?(id)

        resource = deep_stringify(body).merge("resourceType" => resource_type, "id" => id)
        @by_type[resource_type].reject! { |r| r["id"] == id }
        add_resource(resource)
        true
      end

      # Minimal in-memory search. Supports the search params the overlay
      # ingest uses: Patient?name=, Claim?patient=, Coverage?beneficiary=,
      # ServiceRequest?patient=, CareTeam?patient=. Matching mirrors how a
      # real FHIR server resolves these references/tokens.
      def fhir_search(resource_type, params = {})
        params = params.transform_keys(&:to_s)
        matches = @by_type[resource_type].select { |r| search_match?(resource_type, r, params) }
                                         .map { |r| deep_stringify(r) }
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
        return false if wanted.nil? || wanted.empty?

        patient_reference_values(resource).include?(wanted)
      end

      def patient_reference_values(resource)
        [
          resource.dig("patient", "reference"),
          resource.dig("beneficiary", "reference"),
          resource.dig("subject", "reference")
        ].compact.filter_map { |ref| patient_reference_token(ref) }
      end

      # This server's Patient references (relative, versioned, or absolute
      # under base_url) become the patient id. An empty or whitespace id
      # matches nothing. Any other reference is left intact so a foreign
      # absolute URL cannot match a local id.
      def patient_reference_token(reference)
        ref = reference.to_s
        id = id_from_reference(ref, type: "Patient")
        return id if id
        return nil if server_patient_reference?(ref)

        ref
      end

      def server_patient_reference?(ref)
        return false unless ref.encoding.ascii_compatible? && ref.valid_encoding?

        ref.start_with?("Patient/", "#{@base_url}/Patient/")
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
