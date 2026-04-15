# frozen_string_literal: true

module Corvid
  module Adapters
    # Abstract adapter interface — the contract between the Corvid engine and
    # any EHR/vault backend. The adapter is the *only* way Corvid touches PHI:
    # all identity, clinical, and free-text data flows through this interface.
    #
    # Per ADR 0003, the adapter is also Corvid's vault: free text is stored
    # via store_text/fetch_text and retrieved via dereference for in-memory
    # display. Corvid never persists PHI in its own tables.
    #
    # Built-in implementations:
    #   MockAdapter — in-memory dev/test (NOT a security boundary)
    #   FhirAdapter — generic FHIR R4 client
    #
    # Vendor adapters (e.g. RPMS, IRIS, Stedi) live in private repos.
    class Base
      # ----------------------------------------------------------------------
      # Patient
      # ----------------------------------------------------------------------

      # Find a patient by opaque token. Returns a PatientReference or nil.
      def find_patient(patient_identifier)
        raise NotImplementedError, "#{self.class}#find_patient not implemented"
      end

      # Search patients by name or other criteria.
      # Returns an array of PatientReference objects.
      def search_patients(query)
        raise NotImplementedError, "#{self.class}#search_patients not implemented"
      end

      # ----------------------------------------------------------------------
      # Practitioner
      # ----------------------------------------------------------------------

      def find_practitioner(practitioner_identifier)
        raise NotImplementedError, "#{self.class}#find_practitioner not implemented"
      end

      def search_practitioners(query)
        raise NotImplementedError, "#{self.class}#search_practitioners not implemented"
      end

      # ----------------------------------------------------------------------
      # Referral / Service Request
      # ----------------------------------------------------------------------

      def find_referral(referral_identifier)
        raise NotImplementedError, "#{self.class}#find_referral not implemented"
      end

      # Create a new referral in the EHR/vault. Returns a new opaque token.
      def create_referral(patient_identifier, params)
        raise NotImplementedError, "#{self.class}#create_referral not implemented"
      end

      def update_referral(referral_identifier, params)
        raise NotImplementedError, "#{self.class}#update_referral not implemented"
      end

      def list_referrals(patient_identifier)
        raise NotImplementedError, "#{self.class}#list_referrals not implemented"
      end

      # ----------------------------------------------------------------------
      # Vault: free-text storage and dereference (ADR 0003)
      # ----------------------------------------------------------------------

      # Store free text in the vault, return an opaque token (e.g. nt_01HK8B...).
      # +kind+ is a symbol like :note, :rationale, :reason, :conditions.
      def store_text(case_token:, kind:, text:)
        raise NotImplementedError, "#{self.class}#store_text not implemented"
      end

      # Retrieve text by token. Returns a string or nil.
      def fetch_text(text_token)
        raise NotImplementedError, "#{self.class}#fetch_text not implemented"
      end

      # Dereference a single token to its underlying record.
      # Returns a hash of PHI for in-memory display use.
      def dereference(token)
        raise NotImplementedError, "#{self.class}#dereference not implemented"
      end

      # Batch dereference. Returns { token => record_hash }.
      def dereference_many(tokens)
        raise NotImplementedError, "#{self.class}#dereference_many not implemented"
      end

      # ----------------------------------------------------------------------
      # Budget
      # ----------------------------------------------------------------------

      def get_budget_summary(facility_identifier: nil)
        raise NotImplementedError, "#{self.class}#get_budget_summary not implemented"
      end

      def create_obligation(referral_identifier, amount, params = {})
        raise NotImplementedError, "#{self.class}#create_obligation not implemented"
      end

      # Reporting reads default to empty/zero so adapters that don't support
      # reporting degrade gracefully.
      def get_obligation_summary(fiscal_year: nil)
        {}
      end

      def get_outstanding_obligations(fiscal_year: nil)
        []
      end

      def get_obligations(fiscal_year: nil)
        []
      end

      # ----------------------------------------------------------------------
      # Site parameters
      # ----------------------------------------------------------------------

      def get_site_params
        raise NotImplementedError, "#{self.class}#get_site_params not implemented"
      end

      # ----------------------------------------------------------------------
      # Care team
      # ----------------------------------------------------------------------

      def get_care_team(patient_identifier)
        raise NotImplementedError, "#{self.class}#get_care_team not implemented"
      end

      # ----------------------------------------------------------------------
      # Clinical reads (optional — adapters may return empty arrays)
      # ----------------------------------------------------------------------

      def get_conditions(patient_identifier)
        []
      end

      def get_medications(patient_identifier)
        []
      end

      def get_coverages(patient_identifier)
        []
      end

      # ----------------------------------------------------------------------
      # Eligibility
      # ----------------------------------------------------------------------

      # Verify enrollment for a patient against a coverage type.
      # Returns a hash of eligibility info or nil.
      def verify_eligibility(patient_identifier, resource_type)
        raise NotImplementedError, "#{self.class}#verify_eligibility not implemented"
      end

      # ----------------------------------------------------------------------
      # Enrollment verification (for PRC eligibility checklist)
      # ----------------------------------------------------------------------

      # Returns { enrolled: bool, membership_number: str|nil,
      #           tribe_name: str|nil, verified_at: datetime }
      def verify_tribal_enrollment(patient_identifier)
        raise NotImplementedError, "#{self.class}#verify_tribal_enrollment not implemented"
      end

      # Returns { ssn_present: bool, dob_present: bool,
      #           birthplace_present: bool, verified_at: datetime }
      def verify_identity_documents(patient_identifier)
        raise NotImplementedError, "#{self.class}#verify_identity_documents not implemented"
      end

      # Returns { on_reservation: bool, address: str|nil,
      #           service_area: str|nil, verified_at: datetime }
      def verify_residency(patient_identifier)
        raise NotImplementedError, "#{self.class}#verify_residency not implemented"
      end
    end
  end
end
