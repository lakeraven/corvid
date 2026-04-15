# frozen_string_literal: true

module Corvid
  # PRC (Purchased/Referred Care) Eligibility Ruleset
  #
  # Defines eligibility rules as methods where parameters declare dependencies.
  # The RulesEngine automatically builds a dependency graph and evaluates
  # rules in the correct order.
  #
  # Input facts (set via engine.set_facts):
  #   - enrollment_number: Patient's tribal enrollment number (e.g., "ANLC-12345")
  #   - service_area: Patient's service area (e.g., "Anchorage")
  #   - reason_for_referral: Clinical reason for the service request
  #   - urgency: Service request urgency (:routine, :urgent, :emergent)
  #   - coverage_type: Patient's coverage type (e.g., "IHS", "Medicare/IHS")
  #   - service_requested: Description of service requested (for messaging)
  #
  # Computed facts:
  #   - is_tribally_enrolled: Whether patient has valid tribal enrollment
  #   - meets_residency: Whether patient is in a valid service area
  #   - has_clinical_justification: Whether reason contains clinical keywords
  #   - urgency_appropriate: Whether urgency matches clinical presentation
  #   - has_clinical_necessity: Combines justification and urgency checks
  #   - has_payor_coordination: Whether coverage type is valid
  #   - is_eligible: Top-level eligibility (all checks must pass)
  class PrcEligibilityRuleset
    VALID_SERVICE_AREAS = %w[Anchorage Fairbanks Juneau Bethel Nome Barrow Sitka Ketchikan].freeze

    CLINICAL_KEYWORDS = %w[chest pain cardiac surgery fracture injury urgent severe chronic failed treatment].freeze

    VALID_COVERAGE_TYPES = ["IHS", "Medicare/IHS", "Private Insurance/IHS", "Medicaid/IHS"].freeze

    # Top-level eligibility: all checks must pass
    def is_eligible(is_tribally_enrolled, meets_residency, has_clinical_necessity, has_payor_coordination)
      is_tribally_enrolled && meets_residency && has_clinical_necessity && has_payor_coordination
    end

    # Check tribal enrollment status
    # Valid format: TRIBE-NUMBERS (e.g., ANLC-12345)
    def is_tribally_enrolled(enrollment_number)
      return false if enrollment_number.nil? || enrollment_number.to_s.strip.empty?
      enrollment_number.to_s.match?(/^[A-Z]+-\d+$/)
    end

    # Check residency/service area
    def meets_residency(service_area)
      VALID_SERVICE_AREAS.include?(service_area)
    end

    # Clinical necessity requires both justification and appropriate urgency
    def has_clinical_necessity(has_clinical_justification, urgency_appropriate)
      has_clinical_justification && urgency_appropriate
    end

    # Check if reason contains clinical keywords
    def has_clinical_justification(reason_for_referral)
      return false if reason_for_referral.nil? || reason_for_referral.to_s.strip.empty?
      reason_text = reason_for_referral.to_s.downcase
      CLINICAL_KEYWORDS.any? { |keyword| reason_text.include?(keyword) }
    end

    # Check if urgency level matches clinical presentation
    def urgency_appropriate(reason_for_referral, urgency, has_clinical_justification)
      return false unless has_clinical_justification
      return false if reason_for_referral.nil? || reason_for_referral.to_s.strip.empty?
      return true if urgency == :routine

      reason_text = reason_for_referral.to_s.downcase

      case urgency
      when :emergent
        reason_text.include?("emergent") || reason_text.include?("chest pain") || reason_text.include?("severe")
      when :urgent
        reason_text.include?("urgent") || reason_text.include?("chest pain") || reason_text.include?("cardiac")
      else
        false
      end
    end

    # Check payor coordination
    def has_payor_coordination(coverage_type)
      VALID_COVERAGE_TYPES.include?(coverage_type&.strip)
    end

    # Generate human-readable message for a fact
    def self.message_for(fact_name, value, context = {})
      case fact_name.to_sym
      when :is_tribally_enrolled
        value ? "Valid tribal enrollment: #{context[:enrollment_number]}" : "Invalid or missing tribal enrollment number"
      when :meets_residency
        value ? "Patient resides in valid service area: #{context[:service_area]}" : "Patient service area '#{context[:service_area]}' is outside coverage region"
      when :has_clinical_justification
        value ? "Clinical justification documented" : (context[:reason_for_referral].to_s.strip.empty? ? "Clinical reason for service request is required" : "Insufficient clinical justification for specialty service request")
      when :urgency_appropriate
        value ? "Urgency level appropriate for clinical presentation" : "Urgency level does not match clinical presentation"
      when :has_clinical_necessity
        if value
          "Clinical necessity documented: #{context[:urgency].to_s.upcase} service request for #{context[:service_requested]}"
        else
          context[:reason_for_referral].to_s.strip.empty? ? "Clinical reason for service request is required" : (!context[:has_clinical_justification] ? "Insufficient clinical justification for specialty service request" : "Urgency level does not match clinical presentation")
        end
      when :has_payor_coordination
        if value
          case context[:coverage_type]&.strip
          when "IHS" then "IHS is primary payor - no coordination required"
          when "Medicare/IHS" then "Medicare is primary payor - IHS will coordinate as secondary"
          when "Private Insurance/IHS" then "Private insurance is primary - IHS will coordinate as secondary"
          when "Medicaid/IHS" then "Medicaid is primary payor - IHS will coordinate as secondary"
          else "Valid payor coordination"
          end
        else
          "Unknown or invalid coverage type: #{context[:coverage_type]}"
        end
      when :is_eligible
        value ? "Patient is eligible for PRC services" : "Patient is not eligible for PRC services"
      else
        "#{fact_name}: #{value}"
      end
    end
  end
end
