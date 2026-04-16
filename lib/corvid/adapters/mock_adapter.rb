# frozen_string_literal: true

require "date"
require "active_support/time"
require "ulid"
require "corvid/adapters/base"
require "corvid/value_objects"

module Corvid
  module Adapters
    # In-memory adapter for development and tests.
    #
    # IMPORTANT: MockAdapter is not a security boundary. It stores all text
    # in process memory in plaintext, generates predictable tokens, and has
    # no access controls. Use only for dev and test environments. Production
    # deployments must wire a real adapter (FhirAdapter or a private vendor
    # adapter from corvid-adapters).
    #
    # Per ADR 0003, MockAdapter implements the full vault interface
    # (store_text, fetch_text, dereference, dereference_many) so engine
    # tests exercise the same token round-trip behavior production uses.
    class MockAdapter < Base
      # Token prefix per kind, used by store_text and dereference.
      TOKEN_PREFIXES = {
        note: "nt",
        reason: "rs",
        rationale: "rn",
        narrative: "nr",
        policy: "po",
        payer: "py",
        conditions: "cn",
        attendees: "at",
        documents: "dc",
        determination: "de"
      }.freeze

      def initialize
        reset!
        seed!
      end

      # ----------------------------------------------------------------------
      # Patient
      # ----------------------------------------------------------------------

      def find_patient(patient_identifier)
        attrs = @patients[patient_identifier.to_s]
        return nil unless attrs

        Corvid::PatientReference.new(
          identifier: patient_identifier.to_s,
          display_name: attrs[:display_name],
          dob: attrs[:dob],
          sex: attrs[:sex],
          ssn_last4: attrs[:ssn_last4]
        )
      end

      def search_patients(query)
        pattern = query.to_s.downcase
        @patients.filter_map do |id, attrs|
          next unless attrs[:display_name].to_s.downcase.include?(pattern)

          find_patient(id)
        end
      end

      # ----------------------------------------------------------------------
      # Practitioner
      # ----------------------------------------------------------------------

      def find_practitioner(practitioner_identifier)
        attrs = @practitioners[practitioner_identifier.to_s]
        return nil unless attrs

        Corvid::PractitionerReference.new(
          identifier: practitioner_identifier.to_s,
          display_name: attrs[:display_name],
          npi: attrs[:npi],
          specialty: attrs[:specialty]
        )
      end

      def search_practitioners(query)
        pattern = query.to_s.downcase
        @practitioners.filter_map do |id, attrs|
          next unless attrs[:display_name].to_s.downcase.include?(pattern)

          find_practitioner(id)
        end
      end

      # ----------------------------------------------------------------------
      # Referral
      # ----------------------------------------------------------------------

      def find_referral(referral_identifier)
        attrs = @referrals[referral_identifier.to_s]
        return nil unless attrs

        build_referral_reference(referral_identifier.to_s, attrs)
      end

      def create_referral(patient_identifier, params)
        token = "rf_#{ULID.generate}"
        @referrals[token] = {
          patient_identifier: patient_identifier.to_s,
          status: "pending",
          estimated_cost: params[:estimated_cost],
          medical_priority_level: params[:medical_priority_level],
          authorization_number: nil,
          emergent: false,
          urgent: false,
          chs_approval_status: "P",
          service_requested: params[:service_requested]
        }
        token
      end

      def update_referral(referral_identifier, params)
        ref = @referrals[referral_identifier.to_s]
        return false unless ref

        ref.merge!(params)
        true
      end

      def list_referrals(patient_identifier)
        @referrals.filter_map do |id, attrs|
          next unless attrs[:patient_identifier] == patient_identifier.to_s

          build_referral_reference(id, attrs)
        end
      end

      # ----------------------------------------------------------------------
      # Vault: store_text / fetch_text / dereference
      # ----------------------------------------------------------------------

      def store_text(case_token:, kind:, text:)
        prefix = TOKEN_PREFIXES.fetch(kind.to_sym) { "tx" }
        token = "#{prefix}_#{ULID.generate}"
        @text_store[token] = text
        token
      end

      def fetch_text(text_token)
        @text_store[text_token.to_s]
      end

      def dereference(token)
        case token.to_s
        when /\Apt_/ then @patients[token.to_s]
        when /\Apr_/ then @practitioners[token.to_s]
        when /\Arf_/ then @referrals[token.to_s]
        else @text_store[token.to_s]
        end
      end

      def dereference_many(tokens)
        tokens.each_with_object({}) { |t, h| h[t] = dereference(t) }
      end

      # ----------------------------------------------------------------------
      # Budget
      # ----------------------------------------------------------------------

      def get_budget_summary(facility_identifier: nil)
        {
          total: 1_000_000.00,
          total_budget: 1_000_000.00,
          obligated: 250_000.00,
          expended: 150_000.00,
          remaining: 750_000.00,
          percent_remaining: 75.0,
          fiscal_year: Date.current.year,
          quarters: {}
        }
      end

      def create_obligation(referral_identifier, amount, params = {})
        true
      end

      # ----------------------------------------------------------------------
      # Site params
      # ----------------------------------------------------------------------

      def get_site_params
        {
          station_number: "9999",
          station_name: "MOCK FACILITY",
          chs_enabled: true,
          notification_grace_period: 72,
          committee_threshold: 50_000
        }
      end

      # ----------------------------------------------------------------------
      # Care team
      # ----------------------------------------------------------------------

      def get_care_team(patient_identifier)
        members = @care_teams[patient_identifier.to_s] || []
        members.map do |attrs|
          Corvid::CareTeamMemberReference.new(
            practitioner_identifier: attrs[:practitioner_identifier],
            role: attrs[:role],
            name: attrs[:name],
            status: attrs[:status]
          )
        end
      end

      # ----------------------------------------------------------------------
      # Eligibility
      # ----------------------------------------------------------------------

      def verify_eligibility(patient_identifier, resource_type)
        {
          eligible: true,
          payer_name: "MOCK #{resource_type.to_s.upcase} PAYER",
          policy_token: store_text(case_token: "ct_x", kind: :policy, text: "MOCK-#{resource_type}-#{patient_identifier}"),
          coverage_start: Date.new(Date.current.year, 1, 1),
          coverage_end: Date.new(Date.current.year, 12, 31)
        }
      end

      # ----------------------------------------------------------------------
      # Enrollment verification
      # ----------------------------------------------------------------------

      def verify_tribal_enrollment(patient_identifier)
        enrollment = @enrollments[patient_identifier.to_s]
        return { enrolled: false, membership_number: nil, tribe_name: nil, verified_at: Time.current } unless enrollment

        {
          enrolled: enrollment[:enrolled],
          membership_number: enrollment[:membership_number],
          tribe_name: enrollment[:tribe_name],
          blood_quantum: enrollment[:blood_quantum],
          member_status: enrollment[:member_status],
          verified_at: Time.current
        }
      end

      def verify_identity_documents(patient_identifier)
        patient = @patients[patient_identifier.to_s]
        return { ssn_present: false, dob_present: false, birthplace_present: false, verified_at: Time.current } unless patient

        {
          ssn_present: patient[:ssn_last4].present?,
          dob_present: patient[:dob].present?,
          birthplace_present: patient[:birthplace].present?,
          verified_at: Time.current
        }
      end

      def verify_residency(patient_identifier)
        residency = @residencies[patient_identifier.to_s]
        return { on_reservation: false, address: nil, service_area: nil, verified_at: Time.current } unless residency

        {
          on_reservation: residency[:on_reservation],
          address: residency[:address],
          service_area: residency[:service_area],
          verified_at: Time.current
        }
      end

      # ----------------------------------------------------------------------
      # Billing / EDI
      # ----------------------------------------------------------------------

      def submit_claim(claim_data)
        ref = "CLM_#{ULID.generate}"
        @claims[ref] = claim_data.merge(status: "accepted", submitted_at: Time.current)
        { claim_reference: ref, status: "accepted" }
      end

      def check_claim_status(claim_reference)
        claim = @claims[claim_reference]
        return { status: "unknown" } unless claim

        { status: claim[:status] || "accepted",
          paid_amount: claim[:paid_amount],
          adjustment_amount: claim[:adjustment_amount],
          paid_date: claim[:paid_date] }
      end

      def fetch_remittances(date_range: nil)
        @remittances.values
      end

      def check_eligibility_detailed(patient_identifier, payer_id)
        { eligible: true, payer_name: "MOCK #{payer_id}", plan_name: "Mock Plan",
          coverage_start: Date.new(Date.current.year, 1, 1),
          coverage_end: Date.new(Date.current.year, 12, 31) }
      end

      def search_payers(query)
        [{ payer_id: "MOCK_PAYER", name: "Mock Payer matching '#{query}'" }]
      end

      def process_payment(amount_cents:, patient_identifier:, description:)
        ref = "PAY_#{ULID.generate}"
        @payments_store[ref] = { amount_cents: amount_cents, patient_identifier: patient_identifier,
                                 description: description, status: "succeeded" }
        { payment_reference: ref, status: "succeeded" }
      end

      def refund_payment(payment_reference)
        payment = @payments_store[payment_reference]
        return { refund_reference: nil, status: "not_found" } unless payment

        payment[:status] = "refunded"
        { refund_reference: "REF_#{ULID.generate}", status: "refunded" }
      end

      # ----------------------------------------------------------------------
      # Test helpers
      # ----------------------------------------------------------------------

      def add_patient(identifier, attrs)
        @patients[identifier.to_s] = attrs
      end

      def add_practitioner(identifier, attrs)
        @practitioners[identifier.to_s] = attrs
      end

      def add_referral(identifier, attrs)
        @referrals[identifier.to_s] = attrs
      end

      def add_care_team(patient_identifier, members)
        @care_teams[patient_identifier.to_s] = members
      end

      def add_enrollment(patient_identifier, attrs)
        @enrollments[patient_identifier.to_s] = attrs
      end

      def add_residency(patient_identifier, attrs)
        @residencies[patient_identifier.to_s] = attrs
      end

      def add_claim(reference, attrs)
        @claims[reference] = attrs
      end

      def add_remittance(reference, attrs)
        @remittances[reference] = attrs
      end

      def reset!
        @patients = {}
        @practitioners = {}
        @referrals = {}
        @care_teams = {}
        @text_store = {}
        @enrollments = {}
        @residencies = {}
        @claims = {}
        @remittances = {}
        @payments_store = {}
      end

      private

      def build_referral_reference(identifier, attrs)
        Corvid::ReferralReference.new(
          identifier: identifier,
          patient_identifier: attrs[:patient_identifier],
          status: attrs[:status],
          reason_token: attrs[:reason_token],
          estimated_cost: attrs[:estimated_cost],
          medical_priority_level: attrs[:medical_priority_level],
          authorization_number: attrs[:authorization_number],
          emergent: attrs[:emergent],
          urgent: attrs[:urgent],
          chs_approval_status: attrs[:chs_approval_status],
          service_requested: attrs[:service_requested]
        )
      end

      def seed!
        # Synthetic seed data per ADR 0003 — obviously fake, not realistic PHI.
        add_patient("pt_seed_001", display_name: "TEST,PATIENT 001", dob: Date.new(1980, 1, 1), sex: "F", ssn_last4: "0001")
        add_practitioner("pr_seed_001", display_name: "TEST,PROVIDER 001", npi: "0000000001", specialty: "TEST")
      end
    end
  end
end
