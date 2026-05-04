# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Corvid
  module Adapters
    # Adapter for baseroll tribal enrollment system.
    # Queries baseroll's API for enrollment, identity, and residency
    # verification to auto-populate the PRC eligibility checklist.
    #
    # PHI-minimized: returns boolean presence flags (e.g., ssn_present),
    # never raw PII. Corvid stores only verification results.
    class BaserollAdapter < Base
      def initialize(api_url:, api_token:)
        @api_url = api_url.chomp("/")
        @api_token = api_token
      end

      # -- Enrollment verification ---------------------------------------------

      def verify_tribal_enrollment(patient_identifier)
        person = fetch_person(patient_identifier)
        return not_enrolled unless person

        {
          enrolled: person["member_status"] == "enrolled",
          membership_number: person["membership_number"],
          tribe_name: person.dig("enrolled_tribe", "name"),
          member_status: person["member_status"],
          verified_at: Time.current
        }
      end

      # -- Identity verification -----------------------------------------------

      def verify_identity_documents(patient_identifier)
        person = fetch_person(patient_identifier)
        return no_identity unless person

        {
          ssn_present: person["ssn_present"] == true,
          dob_present: person["born_on"].present?,
          birthplace_present: person["birthplace"].present?,
          verified_at: Time.current
        }
      end

      # -- Residency verification ----------------------------------------------

      def verify_residency(patient_identifier)
        person = fetch_person(patient_identifier)
        return no_residency unless person

        addresses = person["addresses"] || []
        current = addresses.first

        {
          on_reservation: current&.dig("on_reservation") == true,
          address: current&.dig("city"),
          service_area: current&.dig("service_area"),
          verified_at: Time.current
        }
      end

      # -- Patient lookup (minimal — name + DOB for display) -------------------

      def find_patient(patient_identifier)
        person = fetch_person(patient_identifier)
        return nil unless person

        {
          identifier: patient_identifier,
          name: person["full_name"],
          dob: person["born_on"]
        }
      end

      def search_patients(query)
        response = get("/api/v1/people", name: query)
        return [] unless response.is_a?(Array)

        response.map do |person|
          {
            identifier: person["id"].to_s,
            name: person["full_name"] || "#{person['first_name']} #{person['last_name']}",
            dob: person["born_on"]
          }
        end
      end

      private

      def fetch_person(identifier)
        @person_cache ||= {}
        @person_cache[identifier.to_s] ||= get("/api/v1/people/#{identifier}")
      end

      def get(path, params = {})
        uri = URI("#{@api_url}#{path}")
        uri.query = URI.encode_www_form(params) if params.any?

        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{@api_token}"
        request["Accept"] = "application/json"

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(request)
        end

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      rescue JSON::ParserError, Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout
        nil
      end

      def not_enrolled
        { enrolled: false, membership_number: nil, tribe_name: nil, verified_at: Time.current }
      end

      def no_identity
        { ssn_present: false, dob_present: false, birthplace_present: false, verified_at: Time.current }
      end

      def no_residency
        { on_reservation: false, address: nil, service_area: nil, verified_at: Time.current }
      end
    end
  end
end
