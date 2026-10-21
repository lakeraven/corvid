# frozen_string_literal: true

require "corvid/adapters/base"
require "corvid/value_objects"

# Shared behavior contract for Corvid::Adapters::Base implementations.
# Including classes must define contract_adapter, contract_seed!, and
# contract_unsupported (Hash of method_name => reason).
module AdapterContractTests
  UNKNOWN_QUERY = "zzzz_contract_no_match"

  CONTRACT_CALLS = {
    check_claim_status: ->(seed) { [ [ seed[:claim_id] ], {} ] },
    check_eligibility_detailed: ->(seed) { [ [ seed[:patient_id], seed[:payer_id] ], {} ] },
    create_obligation: ->(seed) { [ [ seed[:referral_id], 100.0 ], {} ] },
    create_referral: lambda do |seed|
      [ [ seed[:patient_id], { service_requested: "TEST,CONTRACT SERVICE", estimated_cost: 100.0 } ], {} ]
    end,
    dereference: ->(seed) { [ [ seed[:patient_id] ], {} ] },
    dereference_many: ->(seed) { [ [ seed[:dereference_tokens] ], {} ] },
    fetch_remittances: ->(_seed) { [ [], { date_range: nil } ] },
    fetch_text: ->(seed) { [ [ seed[:text_token] ], {} ] },
    find_patient: ->(seed) { [ [ seed[:patient_id] ], {} ] },
    find_practitioner: ->(seed) { [ [ seed[:practitioner_id] ], {} ] },
    find_referral: ->(seed) { [ [ seed[:referral_id] ], {} ] },
    get_budget_summary: ->(_seed) { [ [], { facility_identifier: nil } ] },
    get_care_team: ->(seed) { [ [ seed[:patient_id] ], {} ] },
    get_conditions: ->(seed) { [ [ seed[:patient_id] ], {} ] },
    get_coverages: ->(seed) { [ [ seed[:patient_id] ], {} ] },
    get_medications: ->(seed) { [ [ seed[:patient_id] ], {} ] },
    get_obligation: ->(seed) { [ [ seed[:obligation_id] ], {} ] },
    get_obligation_by_referral: ->(seed) { [ [ seed[:referral_id] ], {} ] },
    get_obligation_summary: ->(_seed) { [ [], { fiscal_year: nil } ] },
    get_obligations: ->(_seed) { [ [], { fiscal_year: nil } ] },
    get_outstanding_obligations: ->(_seed) { [ [], { fiscal_year: nil } ] },
    get_payments: ->(seed) { [ [], { obligation_id: seed[:obligation_id] } ] },
    get_site_params: ->(_seed) { [ [], {} ] },
    list_claims: ->(seed) { [ [ seed[:patient_id] ], {} ] },
    list_referrals: ->(seed) { [ [ seed[:patient_id] ], {} ] },
    process_payment: lambda do |seed|
      [ [], { amount_cents: 100, patient_identifier: seed[:patient_id], description: "TEST CONTRACT PAYMENT" } ]
    end,
    record_payment: lambda do |seed|
      [ [], { obligation_id: seed[:obligation_id], amount: 1.0, payment_date: Date.new(2026, 1, 1) } ]
    end,
    refund_payment: ->(seed) { [ [ seed[:payment_id] ], {} ] },
    release_obligation: ->(seed) { [ [ seed[:obligation_id] ], {} ] },
    search_patients: ->(seed) { [ [ seed[:patient_search_query] ], {} ] },
    search_payers: ->(_seed) { [ [ "TEST" ], {} ] },
    search_practitioners: ->(seed) { [ [ seed[:practitioner_search_query] ], {} ] },
    store_text: lambda do |seed|
      [ [], { case_token: seed[:case_token], kind: :note, text: "TEST CONTRACT NOTE" } ]
    end,
    submit_claim: ->(_seed) { [ [ { service_code: "99213", amount: 100.0 } ], {} ] },
    update_obligation_status: ->(seed) { [ [ seed[:obligation_id] ], { status: "PENDING" } ] },
    update_referral: ->(seed) { [ [ seed[:referral_id], { status: "active" } ], {} ] },
    verify_eligibility: ->(seed) { [ [ seed[:patient_id], "medicaid" ], {} ] },
    verify_identity_documents: ->(seed) { [ [ seed[:patient_id] ], {} ] },
    verify_residency: ->(seed) { [ [ seed[:patient_id] ], {} ] },
    verify_tribal_enrollment: ->(seed) { [ [ seed[:patient_id] ], {} ] }
  }.freeze

  FIND_REFERENCE_CLASS = {
    find_patient: Corvid::PatientReference,
    find_practitioner: Corvid::PractitionerReference,
    find_referral: Corvid::ReferralReference
  }.freeze

  def self.included(base)
    base_methods = Corvid::Adapters::Base.public_instance_methods(false).sort

    base.class_eval do
      include AdapterContractTests::Assertions

      base_methods.each do |method_name|
        define_method(:"test_contract_#{method_name}") do
          validate_contract_unsupported!
          seed = contract_seed!
          if contract_unsupported.key?(method_name)
            assert_contract_unsupported(method_name, seed)
          else
            assert_contract_implemented(method_name, seed)
          end
        end
      end
    end
  end

  module Assertions
    def contract_unsupported
      {}
    end

    def validate_contract_unsupported!
      return if @contract_unsupported_validated

      base_methods = Corvid::Adapters::Base.public_instance_methods(false)
      unsupported = contract_unsupported
      assert unsupported.is_a?(Hash), "contract_unsupported must be a Hash"

      unsupported.each do |method_name, reason|
        assert base_methods.include?(method_name),
               "contract_unsupported key #{method_name.inspect} is not a Base public method"
        assert reason.is_a?(String) && !reason.strip.empty?,
               "contract_unsupported[#{method_name.inspect}] must be a non-empty String reason"
      end

      @contract_unsupported_validated = true
    end

    def contract_call_args(method_name, seed)
      builder = AdapterContractTests::CONTRACT_CALLS[method_name]
      flunk("add a CONTRACT_CALLS entry for #{method_name}") unless builder

      builder.call(seed)
    end

    def invoke_contract(method_name, seed)
      args, kwargs = contract_call_args(method_name, seed)
      contract_adapter.public_send(method_name, *args, **kwargs)
    end

    def assert_contract_unsupported(method_name, seed)
      args, kwargs = contract_call_args(method_name, seed)
      error = assert_raises(NotImplementedError) do
        contract_adapter.public_send(method_name, *args, **kwargs)
      end
      assert_match(/#{method_name}/, error.message)
    end

    def assert_contract_implemented(method_name, seed)
      args, kwargs = contract_call_args(method_name, seed)

      result = contract_adapter.public_send(method_name, *args, **kwargs)

      assert_implemented_shape(method_name, result, seed)

      assert_unknown_lookup_behavior(method_name, seed) if lookup_method?(method_name)
    end

    def lookup_method?(method_name)
      method_name.start_with?("find_") ||
        method_name.start_with?("search_") ||
        method_name.start_with?("list_") ||
        %i[get_care_team get_conditions get_medications get_coverages get_obligation get_obligation_by_referral
           get_payments fetch_text verify_eligibility verify_tribal_enrollment verify_identity_documents
           verify_residency].include?(method_name)
    end

    def assert_unknown_lookup_behavior(method_name, seed)
      adapter = contract_adapter
      case method_name
      when :find_patient
        assert_nil adapter.find_patient(seed[:unknown_patient_id])
      when :find_practitioner
        assert_nil adapter.find_practitioner(seed[:unknown_practitioner_id])
      when :find_referral
        assert_nil adapter.find_referral(seed[:unknown_referral_id])
      when :search_patients, :search_practitioners, :search_payers
        empty = adapter.public_send(method_name, AdapterContractTests::UNKNOWN_QUERY)
        assert_instance_of Array, empty
      when :list_referrals, :list_claims
        empty = adapter.public_send(method_name, seed[:unknown_patient_id])
        assert_equal [], empty
      when :get_care_team, :get_conditions, :get_medications, :get_coverages
        empty = adapter.public_send(method_name, seed[:unknown_patient_id])
        assert_equal [], empty
      when :get_obligation
        assert_nil adapter.get_obligation(seed[:unknown_obligation_id])
      when :get_obligation_by_referral
        assert_nil adapter.get_obligation_by_referral(seed[:unknown_referral_id])
      when :get_payments
        empty = adapter.get_payments(obligation_id: seed[:unknown_obligation_id])
        assert_equal [], empty
      when :fetch_text
        assert_nil adapter.fetch_text("nt_contract_unknown_token")
      when :verify_eligibility
        result = adapter.verify_eligibility(seed[:unknown_patient_id], "medicaid")
        assert result.nil? || result.is_a?(Hash), "verify_eligibility for unknown patient must be nil or Hash"
      when :verify_tribal_enrollment
        result = adapter.verify_tribal_enrollment(seed[:unknown_patient_id])
        assert_tribal_enrollment_shape(result)
      when :verify_identity_documents
        result = adapter.verify_identity_documents(seed[:unknown_patient_id])
        assert_identity_documents_shape(result)
      when :verify_residency
        result = adapter.verify_residency(seed[:unknown_patient_id])
        assert_residency_shape(result)
      end
    end

    def assert_implemented_shape(method_name, result, seed)
      case method_name
      when :find_patient, :find_practitioner, :find_referral
        ref_class = AdapterContractTests::FIND_REFERENCE_CLASS.fetch(method_name)
        assert_instance_of ref_class, result
      when :search_patients
        assert_array_of(result, Corvid::PatientReference)
      when :search_practitioners
        assert_array_of(result, Corvid::PractitionerReference)
      when :search_payers
        assert_instance_of Array, result
      when :list_referrals
        assert_array_of(result, Corvid::ReferralReference)
      when :list_claims
        assert_array_of(result, Corvid::ClaimLineReference)
      when :create_referral, :store_text
        assert_token(result)
      when :update_referral
        assert_boolean(result)
      when :fetch_text
        assert result.nil? || result.is_a?(String), "fetch_text must return String or nil"
      when :dereference
        assert result.is_a?(Hash) || result.is_a?(String), "dereference must return Hash, String, or nil"
      when :dereference_many
        assert_instance_of Hash, result
      when :get_budget_summary, :get_site_params, :get_obligation_summary
        assert_instance_of Hash, result
      when :get_obligations, :get_outstanding_obligations, :get_payments, :fetch_remittances
        assert_instance_of Array, result
      when :get_obligation, :get_obligation_by_referral
        assert result.nil? || result.is_a?(Hash), "obligation lookup must be Hash or nil"
      when :create_obligation, :release_obligation, :record_payment, :update_obligation_status
        assert_open_struct_result(result)
      when :get_care_team
        assert_array_of(result, Corvid::CareTeamMemberReference)
      when :get_conditions, :get_medications, :get_coverages
        assert_instance_of Array, result
      when :verify_eligibility
        assert_verify_eligibility_shape(result)
      when :verify_tribal_enrollment
        assert_tribal_enrollment_shape(result)
      when :verify_identity_documents
        assert_identity_documents_shape(result)
      when :verify_residency
        assert_residency_shape(result)
      when :submit_claim
        assert_keys(result, %i[claim_identifier status])
      when :check_claim_status
        assert_keys(result, %i[status])
      when :check_eligibility_detailed
        assert_keys(result, %i[eligible])
      when :process_payment
        assert_keys(result, %i[payment_identifier status])
      when :refund_payment
        assert_keys(result, %i[refund_identifier status])
      else
        flunk("no shape assertion for implemented method #{method_name}")
      end
    end

    def assert_reference_or_nil(value, ref_class)
      assert value.nil? || value.is_a?(ref_class), "expected #{ref_class} or nil, got #{value.class}"
    end

    def assert_array_of(value, element_class)
      assert_instance_of Array, value
      value.each { |element| assert_instance_of element_class, element }
    end

    def assert_token(value)
      assert_instance_of String, value
      refute_empty value
    end

    def assert_boolean(value)
      assert_includes [ true, false ], value
    end

    def assert_keys(value, keys)
      assert_instance_of Hash, value
      keys.each { |key| assert value.key?(key), "expected key #{key.inspect} in #{value.inspect}" }
    end

    def assert_open_struct_result(value)
      assert value.respond_to?(:success?), "expected OpenStruct-like result with success?"
      assert_includes [ true, false ], value.success?
    end

    def assert_verify_eligibility_shape(value)
      return if value.nil?

      assert_instance_of Hash, value
      return unless value.key?(:eligible)

      eligible = value[:eligible]
      assert_includes [ true, false ], eligible, ":eligible must be true or false when present"
    end

    def assert_tribal_enrollment_shape(value)
      assert_instance_of Hash, value
      assert_keys(value, %i[enrolled membership_number tribe_name tribe_code confidence verified_at])
      assert_includes [ true, false ], value[:enrolled]
      assert_includes %i[verified stale unavailable], value[:confidence]
      assert value[:verified_at].respond_to?(:to_time), "verified_at must be time-like"
    end

    def assert_identity_documents_shape(value)
      assert_instance_of Hash, value
      assert_keys(value, %i[ssn_present dob_present birthplace_present verified_at])
      %i[ssn_present dob_present birthplace_present].each do |key|
        assert_includes [ true, false ], value[key]
      end
      assert value[:verified_at].respond_to?(:to_time), "verified_at must be time-like"
    end

    def assert_residency_shape(value)
      assert_instance_of Hash, value
      assert_keys(value, %i[on_reservation address service_area verified_at])
      assert_includes [ true, false ], value[:on_reservation]
      assert value[:verified_at].respond_to?(:to_time), "verified_at must be time-like"
    end
  end
end
