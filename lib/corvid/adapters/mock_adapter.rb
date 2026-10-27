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

      # Fixed directory. search_payers filters this; it does not invent a hit
      # whose name contains the query.
      SEEDED_PAYERS = [
        { payer_identifier: "MOCK_PAYER", name: "Mock Payer" }
      ].freeze

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
          service_requested: params[:service_requested],
          requesting_provider_identifier: params[:requesting_provider_identifier]
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
        return nil if blank_patient_identifier?(patient_identifier)

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
        tokens.each_with_object({}) do |token, records|
          value = dereference(token)
          records[token] = value unless value.nil?
        end
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
        if amount > 999_999_000
          OpenStruct.new(success?: false, failure?: true, message: "Insufficient funds", id: nil)
        else
          id = "OBL-#{SecureRandom.hex(4)}"
          @obligations ||= {}
          @obligations[id] = { id: id, referral_ien: referral_identifier, amount: amount, status: "PENDING", amount_due: amount, payments: [] }.merge(params)
          OpenStruct.new(success?: true, failure?: false, id: id, message: nil)
        end
      end

      def release_obligation(obligation_id)
        @obligations ||= {}
        if @obligations.key?(obligation_id)
          @obligations[obligation_id][:status] = "RELEASED"
          OpenStruct.new(success?: true, failure?: false)
        else
          OpenStruct.new(success?: false, failure?: true, message: "Obligation not found")
        end
      end

      def get_obligation(obligation_id)
        @obligations ||= {}
        @obligations[obligation_id]
      end

      def get_obligation_by_referral(referral_identifier)
        @obligations ||= {}
        @obligations.values.find { |o| o[:referral_ien] == referral_identifier }
      end

      def record_payment(obligation_id:, amount:, payment_date: nil, check_number: nil, vendor_id: nil)
        @obligations ||= {}
        obligation = @obligations[obligation_id]
        return OpenStruct.new(success?: false, failure?: true, message: "Obligation not found") unless obligation
        return OpenStruct.new(success?: false, failure?: true, message: "Amount exceeds obligation") if amount > obligation[:amount_due]

        payment_id = "PMT-#{SecureRandom.hex(4)}"
        payment = { id: payment_id, amount: amount, payment_date: payment_date || Date.current, check_number: check_number, vendor_id: vendor_id }
        obligation[:payments] << payment
        obligation[:amount_due] -= amount
        obligation[:status] = "PAID" if obligation[:amount_due] <= 0
        OpenStruct.new(success?: true, failure?: false, id: payment_id)
      end

      def get_payments(obligation_id:)
        @obligations ||= {}
        @obligations.dig(obligation_id, :payments) || []
      end

      def update_obligation_status(obligation_id, status:)
        @obligations ||= {}
        valid_statuses = %w[PENDING PAID CANCELLED PARTIAL]
        return OpenStruct.new(success?: false, failure?: true, message: "Invalid status") unless valid_statuses.include?(status)

        obligation = @obligations[obligation_id]
        return OpenStruct.new(success?: false, failure?: true, message: "Obligation not found") unless obligation

        obligation[:status] = status
        OpenStruct.new(success?: true, failure?: false)
      end

      def get_outstanding_obligations(fiscal_year: nil)
        @obligations ||= {}
        @obligations.values.select { |o| %w[PENDING PARTIAL].include?(o[:status]) }
      end

      def get_obligation_summary(fiscal_year: nil)
        @obligations ||= {}
        total_obligated = @obligations.values.sum { |o| o[:amount] }
        total_paid = @obligations.values.sum { |o| o[:payments]&.sum { |p| p[:amount] } || 0 }
        {
          total_obligated: total_obligated,
          total_paid: total_paid,
          total_outstanding: total_obligated - total_paid,
          by_status: @obligations.values.group_by { |o| o[:status] }.transform_values(&:count)
        }
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
        return nil if blank_patient_identifier?(patient_identifier)

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

      def verify_eligibility(patient_identifier, resource_type, date_of_service: nil)
        answered_on, defaulted = resolve_inquiry_date(date_of_service)
        coverage = coverage_for(patient_identifier, resource_type, :coverage_type)
        return nil unless coverage

        result = eligibility_from_coverage(patient_identifier, resource_type, coverage)
        return nil unless result

        apply_medicaid_scenario!(result, coverage, answered_on)
        mark_ineligible_outside_inquiry!(result, answered_on)
        result.merge(date_of_service: answered_on, date_of_service_defaulted: defaulted)
      end

      # ----------------------------------------------------------------------
      # Enrollment verification
      # ----------------------------------------------------------------------

      def verify_tribal_enrollment(patient_identifier)
        enrollment = @enrollments[patient_identifier.to_s]
        return tribal_enrollment_unavailable unless enrollment

        {
          enrolled: enrollment[:enrolled],
          membership_number: enrollment[:membership_number],
          tribe_name: enrollment[:tribe_name],
          tribe_code: enrollment[:tribe_code],
          blood_quantum: normalize_blood_quantum(enrollment[:blood_quantum]),
          member_status: enrollment[:member_status],
          confidence: normalize_tribal_confidence(enrollment[:confidence]),
          verified_at: verification_timestamp
        }
      end

      def verify_identity_documents(patient_identifier)
        patient = @patients[patient_identifier.to_s]
        return { ssn_present: false, dob_present: false, birthplace_present: false, verified_at: verification_timestamp } unless patient

        {
          ssn_present: patient[:ssn_last4].present?,
          dob_present: patient[:dob].present?,
          birthplace_present: patient[:birthplace].present?,
          verified_at: verification_timestamp
        }
      end

      def verify_residency(patient_identifier)
        residency = @residencies[patient_identifier.to_s]
        return { on_reservation: false, address: nil, service_area: nil, verified_at: verification_timestamp } unless residency

        {
          on_reservation: residency[:on_reservation],
          address: residency[:address],
          service_area: residency[:service_area],
          verified_at: verification_timestamp
        }
      end

      # ----------------------------------------------------------------------
      # Billing / EDI
      # ----------------------------------------------------------------------

      def submit_claim(claim_data)
        ref = "CLM_#{ULID.generate}"
        @claims[ref] = claim_data.merge(status: "accepted", submitted_at: Time.current)
        { claim_identifier: ref, status: "accepted" }
      end

      def check_claim_status(claim_identifier)
        claim = @claims[claim_identifier]
        return nil unless claim

        # The four base keys are always present (the adapter contract checks
        # for them); the optional rejection/denial keys only when seeded.
        { status: claim[:status] || "accepted",
          paid_amount: claim[:paid_amount],
          adjustment_amount: claim[:adjustment_amount],
          paid_date: claim[:paid_date] }.merge(
          { rejection_reason_token: claim[:rejection_reason_token],
            denial_reason_codes: claim[:denial_reason_codes] }.compact
        )
      end

      def fetch_remittances(date_range: nil)
        @remittances.values
      end

      # A check that names no payer is undetermined, never the first coverage.
      def check_eligibility_detailed(patient_identifier, payer_identifier, date_of_service: nil)
        answered_on, defaulted = resolve_inquiry_date(date_of_service)
        detailed_eligibility_result(patient_identifier, payer_identifier).merge(
          date_of_service: answered_on,
          date_of_service_defaulted: defaulted
        )
      end

      def search_payers(query)
        pattern = query.to_s.downcase
        SEEDED_PAYERS.filter_map do |payer|
          name = payer[:name].to_s.downcase
          identifier = payer[:payer_identifier].to_s.downcase
          next unless name.include?(pattern) || identifier.include?(pattern)

          payer.dup
        end
      end

      def process_payment(amount_cents:, patient_identifier:, description:)
        ref = "PAY_#{ULID.generate}"
        @payments_store[ref] = { amount_cents: amount_cents, patient_identifier: patient_identifier,
                                 description: description, status: "processing" }
        { payment_identifier: ref, status: "processing" }
      end

      def refund_payment(payment_identifier)
        payment = @payments_store[payment_identifier]
        return { refund_identifier: nil, status: "not_found" } unless payment

        payment[:status] = "refunded"
        { refund_identifier: "REF_#{ULID.generate}", status: "refunded" }
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

      def add_coverage(patient_identifier, attrs = {}, **extra)
        row = attrs.is_a?(Hash) ? attrs.merge(extra) : extra
        @coverages[patient_identifier.to_s] ||= []
        @coverages[patient_identifier.to_s] << row
      end

      # Synthetic Medicaid answers for issue #712. Dates are applied when
      # the inquiry date is known, so the scenario follows that month.
      MEDICAID_ELIGIBILITY_SCENARIOS = %i[
        active_this_month_only
        mid_month_end
        placeholder_end
        inactive_with_covering_dates
      ].freeze

      def seed_medicaid_eligibility_scenario(patient_identifier, scenario)
        unless MEDICAID_ELIGIBILITY_SCENARIOS.include?(scenario)
          raise ArgumentError, "unknown medicaid eligibility scenario"
        end

        add_coverage(patient_identifier, medicaid_scenario_coverage(scenario))
      end

      def get_coverages(patient_identifier)
        @coverages[patient_identifier.to_s] || []
      end

      def add_condition(patient_identifier, reference)
        unless reference.is_a?(Corvid::ConditionReference)
          raise ArgumentError, "expected ConditionReference"
        end

        (@conditions[patient_identifier.to_s] ||= []) << reference
      end

      def get_conditions(patient_identifier)
        return nil if blank_patient_identifier?(patient_identifier)

        copied_references(@conditions[patient_identifier.to_s])
      end

      def add_medication(patient_identifier, reference)
        unless reference.is_a?(Corvid::MedicationReference)
          raise ArgumentError, "expected MedicationReference"
        end

        (@medications[patient_identifier.to_s] ||= []) << reference
      end

      def get_medications(patient_identifier)
        return nil if blank_patient_identifier?(patient_identifier)

        copied_references(@medications[patient_identifier.to_s])
      end

      def add_claim_line(patient_identifier, reference)
        unless reference.is_a?(Corvid::ClaimLineReference)
          raise ArgumentError, "expected ClaimLineReference"
        end

        (@claim_lines[patient_identifier.to_s] ||= []) << reference
      end

      def list_claims(patient_identifier)
        return nil if blank_patient_identifier?(patient_identifier)

        copied_references(@claim_lines[patient_identifier.to_s])
      end

      def reset!
        @patients = {}
        @practitioners = {}
        @referrals = {}
        @care_teams = {}
        @text_store = {}
        @enrollments = {}
        @residencies = {}
        @coverages = {}
        @conditions = {}
        @medications = {}
        @claim_lines = {}
        @claims = {}
        @remittances = {}
        @payments_store = {}
      end

      private

      # Unknown record is not a denial. enrolled stays nil.
      def tribal_enrollment_unavailable
        {
          enrolled: nil,
          membership_number: nil,
          tribe_name: nil,
          tribe_code: nil,
          member_status: nil,
          blood_quantum: nil,
          confidence: :unavailable,
          verified_at: verification_timestamp
        }
      end

      # Matches the request against the coverage's own fields: its type
      # (coverage_type, or resource_type when coverage_type is absent) for a
      # type, payer_identifier for a payer. A payer or plan name that
      # happens to spell the requested word is not a match, and a request
      # that matches nothing is unknown. A nil, empty, or whitespace-only
      # request is unknown and does not fall back to the first coverage.
      # Never substitute a different coverage. The most recently recorded
      # match wins.
      def coverage_for(patient_identifier, requested, field)
        coverages = @coverages[patient_identifier.to_s]
        return nil if coverages.nil? || coverages.empty?

        needle = requested.to_s.downcase
        return nil if needle.strip.empty?

        coverages.reverse.find { |coverage| coverage_field(coverage, field).to_s.downcase == needle }
      end

      def coverage_field(coverage, field)
        return coverage[field] unless field == :coverage_type

        coverage.key?(:coverage_type) ? coverage[:coverage_type] : coverage[:resource_type]
      end

      # A recorded period or renewal key, even an explicit nil (an unknown
      # or open bound), replaces the default; an omitted key keeps it.
      def apply_recorded_dates(result, coverage)
        %i[coverage_start coverage_end renewal_date].each do |key|
          result[key] = coverage[key] if coverage.key?(key)
        end
        result
      end

      # Only an explicit eligible: true verifies; a coverage that does not
      # say is not eligible. A non-boolean answer stays undetermined (nil).
      def eligibility_from_coverage(patient_identifier, resource_type, coverage)
        eligible = coverage[:eligible]
        return nil if coverage.key?(:eligible) && eligible != true && eligible != false

        result = {
          eligible: eligible == true,
          payer_name: coverage[:payer_name] || "MOCK #{resource_type.to_s.upcase} PAYER",
          policy_token: coverage[:policy_token] || policy_token_for(patient_identifier, resource_type),
          coverage_start: year_start,
          coverage_end: year_end
        }
        result[:service_active] = coverage[:service_active] if coverage.key?(:service_active)
        apply_recorded_dates(result, coverage)
      end

      def detailed_eligibility_result(patient_identifier, payer_identifier)
        return undetermined_detailed_eligibility if payer_identifier.to_s.strip.empty?

        coverage = coverage_for(patient_identifier, payer_identifier, :payer_identifier)
        return undetermined_detailed_eligibility unless coverage

        detailed_eligibility_from_coverage(payer_identifier, coverage)
      end

      def medicaid_scenario_coverage(scenario)
        {
          coverage_type: "medicaid",
          payer_name: "MOCK MEDICAID PAYER",
          plan_name: "TEST PLAN 712",
          eligible: true,
          medicaid_eligibility_scenario: scenario
        }
      end

      # Plan dates follow the inquiry month. Inactive service stays
      # eligible at the plan level and reports service_active false.
      def apply_medicaid_scenario!(result, coverage, inquiry_date)
        scenario = coverage[:medicaid_eligibility_scenario]
        return unless MEDICAID_ELIGIBILITY_SCENARIOS.include?(scenario)

        result[:coverage_start] = Date.new(inquiry_date.year, inquiry_date.month, 1)
        result[:coverage_end] = scenario_coverage_end(scenario, inquiry_date)
        result[:eligible] = true
        result[:service_active] = false if scenario == :inactive_with_covering_dates
      end

      # Plan dates that miss the inquiry are not eligible. A seeded
      # scenario is checked the same way as a recorded row.
      def mark_ineligible_outside_inquiry!(result, inquiry_date)
        return unless result[:eligible] == true
        return unless outside_inquiry_period?(result[:coverage_start], result[:coverage_end], inquiry_date)

        result[:eligible] = false
      end

      # A start after the inquiry, or an end before it, misses. A nil
      # bound does not.
      def outside_inquiry_period?(coverage_start, coverage_end, inquiry_date)
        return false unless inquiry_date.is_a?(Date)

        (coverage_start.is_a?(Date) && coverage_start > inquiry_date) ||
          (coverage_end.is_a?(Date) && coverage_end < inquiry_date)
      end

      def scenario_coverage_end(scenario, inquiry_date)
        case scenario
        when :mid_month_end
          Date.new(inquiry_date.year, inquiry_date.month, 14)
        when :placeholder_end
          Date.new(9999, 12, 31)
        else
          Date.new(inquiry_date.year, inquiry_date.month, -1)
        end
      end

      def detailed_eligibility_from_coverage(payer_identifier, coverage)
        {
          eligible: coverage[:eligible] == true,
          payer_name: coverage[:payer_name] || "MOCK #{payer_identifier}",
          plan_name: coverage[:plan_name] || "Mock Plan",
          coverage_start: coverage[:coverage_start] || year_start,
          coverage_end: coverage[:coverage_end] || year_end
        }
      end

      def undetermined_detailed_eligibility
        {
          eligible: false,
          payer_name: nil,
          plan_name: nil,
          coverage_start: nil,
          coverage_end: nil
        }
      end

      def policy_token_for(patient_identifier, resource_type)
        store_text(
          case_token: "ct_x",
          kind: :policy,
          text: "MOCK-#{resource_type}-#{patient_identifier}"
        )
      end

      def year_start
        Date.new(Date.current.year, 1, 1)
      end

      def year_end
        Date.new(Date.current.year, 12, 31)
      end

      # Whole-second clock so a repeated check in the same second reports
      # the same verified_at.
      def verification_timestamp
        Time.current.change(usec: 0)
      end

      def blank_patient_identifier?(patient_identifier)
        patient_identifier.nil? || patient_identifier.to_s.strip.empty?
      end

      # Frozen string copies so a caller cannot mutate stored clinical data.
      def copied_references(stored)
        (stored || []).map { |reference| copied_reference(reference) }
      end

      def copied_reference(reference)
        values = reference.to_h.transform_values { |value| frozen_string_copy(value) }
        reference.class.new(**values)
      end

      def frozen_string_copy(value)
        value.is_a?(String) ? value.dup.freeze : value
      end

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
          service_requested: attrs[:service_requested],
          requesting_provider_identifier: attrs[:requesting_provider_identifier]
        )
      end

      def seed!
        # Synthetic seed data per ADR 0003 - obviously fake, not realistic PHI.
        add_patient("pt_seed_001", display_name: "TEST,PATIENT 001", dob: Date.new(1980, 1, 1), sex: "F", ssn_last4: "0001")
        add_practitioner("pr_seed_001", display_name: "TEST,PROVIDER 001", npi: "0000000001", specialty: "TEST")
      end
    end
  end
end
