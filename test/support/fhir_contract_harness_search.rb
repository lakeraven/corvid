# frozen_string_literal: true

# Shared in-memory FHIR search semantics for adapter contract harnesses.
module FhirContractHarnessSearch
  ALLOWED_SEARCH_PARAMS = {
    "Patient" => %w[name],
    "Practitioner" => %w[name],
    "ServiceRequest" => %w[patient],
    "Claim" => %w[patient],
    "Coverage" => %w[beneficiary],
    "CareTeam" => %w[patient]
  }.freeze

  PATIENT_PARAM_REFERENCE_FIELD = {
    "Claim" => "patient",
    "CareTeam" => "subject",
    "ServiceRequest" => "subject",
    "Condition" => "subject",
    "MedicationRequest" => "subject"
  }.freeze

  def contract_harness_search_match?(resource_type, resource, params)
    params.each_key do |key|
      allowed = ALLOWED_SEARCH_PARAMS[resource_type]
      unless allowed&.include?(key)
        raise ArgumentError, "unsupported FHIR search parameter #{key.inspect} for #{resource_type}"
      end
    end

    params.all? do |key, value|
      case key
      when "patient", "beneficiary", "subject"
        contract_harness_reference_matches?(resource_type, resource, key, value)
      when "name"
        contract_harness_name_matches?(resource, value)
      else
        true
      end
    end
  end

  def contract_harness_reference_matches?(resource_type, resource, param_key, value)
    wanted = normalize_patient_reference_token(value)
    field = reference_field_for_search(resource_type, param_key)
    ref = resource.dig(field, "reference")
    return false unless ref

    normalize_patient_reference_token(ref) == wanted
  end

  def reference_field_for_search(resource_type, param_key)
    case param_key
    when "beneficiary" then "beneficiary"
    when "subject" then "subject"
    when "patient" then PATIENT_PARAM_REFERENCE_FIELD.fetch(resource_type, "patient")
    else
      "patient"
    end
  end

  def normalize_patient_reference_token(value)
    value.to_s.sub(%r{\APatient/}, "")
  end

  def contract_harness_name_matches?(resource, value)
    needle = value.to_s.downcase
    Array(resource["name"]).any? do |n|
      [ n["family"], *Array(n["given"]) ].compact.any? { |part| part.downcase.include?(needle) }
    end
  end
end
