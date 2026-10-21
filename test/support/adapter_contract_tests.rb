# frozen_string_literal: true

require "corvid/adapters/base"
require "corvid/value_objects"

# Shared behavior contract for Corvid::Adapters::Base implementations.
# Including classes must define contract_adapter, contract_seed!, and
# contract_unsupported (Hash of method_name => reason). Optional
# contract_fail_closed_stubs documents methods that return a fail-closed
# stub instead of raising (Hash of method_name => reason, default {}).
module AdapterContractTests
  UNKNOWN_QUERY = "zzzz_contract_no_match"
  UNKNOWN_TEXT_TOKEN = "nt_contract_unknown_token"
  UNKNOWN_CLAIM_IDENTIFIER = "clm_contract_unknown"

  REQUIRED_SEED_KEYS = %i[
    patient_identifier
    patient_identifier_tribal_no_confidence
    unknown_patient_identifier
    patient_search_query
    practitioner_identifier
    unknown_practitioner_identifier
    practitioner_search_query
    referral_identifier
    unknown_referral_identifier
    text_token
    stored_text
    case_token
    obligation_identifier
    unknown_obligation_identifier
    payment_identifier
    unknown_payment_identifier
    claim_identifier
    payer_identifier
    unknown_payer_identifier
    coverage_resource_type
    other_resource_type
    dereference_tokens
    care_team_seeded
    claims_listable
    obligation_seeded
  ].freeze

  REFUND_SUCCESS_STATUSES = %w[refunded succeeded].freeze

  NO_IDENTIFIER_METHODS = %i[
    fetch_remittances
    get_budget_summary
    get_obligation_summary
    get_obligations
    get_outstanding_obligations
    get_site_params
    submit_claim
  ].freeze

  DECLINED_UNKNOWN_IDENTIFIER_CHECKS = {
    create_obligation: "adapters keep no referral registry; the host owns referrals (same as create_referral)",
    create_referral: "adapters do not hold a patient registry for referral writes",
    process_payment: "adapters do not hold a patient registry for payment writes",
    store_text: "adapters do not hold a case registry for vault writes"
  }.freeze

  UNKNOWN_IDENTIFIER_RULES = {
    check_claim_status: "unknown claim identifier yields nil status hash",
    check_eligibility_detailed: "unknown patient or payer must not return eligible: true",
    dereference: "unknown token yields nil",
    dereference_many: "unknown tokens omitted or empty batch yields {}",
    fetch_text: "unknown text token yields nil",
    find_patient: "unknown patient token yields nil",
    find_practitioner: "unknown practitioner token yields nil",
    find_referral: "unknown referral token yields nil",
    get_care_team: "unknown patient yields empty array",
    get_conditions: "unknown patient yields empty array",
    get_coverages: "unknown patient yields empty array",
    get_medications: "unknown patient yields empty array",
    get_obligation: "unknown obligation id yields nil",
    get_obligation_by_referral: "unknown referral yields nil obligation",
    get_payments: "unknown obligation id yields empty array",
    list_claims: "unknown patient yields empty array",
    list_referrals: "unknown patient yields empty array",
    record_payment: "unknown obligation must not succeed",
    refund_payment: "unknown payment must not report refund success",
    release_obligation: "unknown obligation must not succeed",
    search_patients: "non-matching query yields empty array",
    search_payers: "non-matching query yields empty array",
    search_practitioners: "non-matching query yields empty array",
    update_obligation_status: "unknown obligation must not succeed",
    update_referral: "unknown referral update returns false",
    verify_eligibility: "unknown patient must not return eligible: true",
    verify_identity_documents: "unknown patient reports all identity fields absent",
    verify_residency: "unknown patient reports not on reservation",
    verify_tribal_enrollment: "unknown patient is not enrolled with :verified confidence"
  }.freeze

  CONTRACT_CALLS = {
    check_claim_status: ->(seed) { [ [ seed[:claim_identifier] ], {} ] },
    check_eligibility_detailed: lambda do |seed|
      [ [ seed[:patient_identifier], seed[:payer_identifier] ], {} ]
    end,
    create_obligation: ->(seed) { [ [ seed[:referral_identifier], 100.0 ], {} ] },
    create_referral: lambda do |seed|
      [ [ seed[:patient_identifier], { service_requested: "TEST,CONTRACT SERVICE", estimated_cost: 100.0 } ], {} ]
    end,
    dereference: ->(seed) { [ [ seed[:patient_identifier] ], {} ] },
    dereference_many: ->(seed) { [ [ seed[:dereference_tokens] ], {} ] },
    fetch_remittances: ->(_seed) { [ [], { date_range: nil } ] },
    fetch_text: ->(seed) { [ [ seed[:text_token] ], {} ] },
    find_patient: ->(seed) { [ [ seed[:patient_identifier] ], {} ] },
    find_practitioner: ->(seed) { [ [ seed[:practitioner_identifier] ], {} ] },
    find_referral: ->(seed) { [ [ seed[:referral_identifier] ], {} ] },
    get_budget_summary: ->(_seed) { [ [], { facility_identifier: nil } ] },
    get_care_team: ->(seed) { [ [ seed[:patient_identifier] ], {} ] },
    get_conditions: ->(seed) { [ [ seed[:patient_identifier] ], {} ] },
    get_coverages: ->(seed) { [ [ seed[:patient_identifier] ], {} ] },
    get_medications: ->(seed) { [ [ seed[:patient_identifier] ], {} ] },
    get_obligation: ->(seed) { [ [ seed[:obligation_identifier] ], {} ] },
    get_obligation_by_referral: ->(seed) { [ [ seed[:referral_identifier] ], {} ] },
    get_obligation_summary: ->(_seed) { [ [], { fiscal_year: nil } ] },
    get_obligations: ->(_seed) { [ [], { fiscal_year: nil } ] },
    get_outstanding_obligations: ->(_seed) { [ [], { fiscal_year: nil } ] },
    get_payments: ->(seed) { [ [], { obligation_id: seed[:obligation_identifier] } ] },
    get_site_params: ->(_seed) { [ [], {} ] },
    list_claims: ->(seed) { [ [ seed[:patient_identifier] ], {} ] },
    list_referrals: ->(seed) { [ [ seed[:patient_identifier] ], {} ] },
    process_payment: lambda do |seed|
      [ [], { amount_cents: 100, patient_identifier: seed[:patient_identifier], description: "TEST CONTRACT PAYMENT" } ]
    end,
    record_payment: lambda do |seed|
      [ [], { obligation_id: seed[:obligation_identifier], amount: 1.0, payment_date: Date.new(2026, 1, 1) } ]
    end,
    refund_payment: ->(seed) { [ [ seed[:payment_identifier] ], {} ] },
    release_obligation: ->(seed) { [ [ seed[:obligation_identifier] ], {} ] },
    search_patients: ->(seed) { [ [ seed[:patient_search_query] ], {} ] },
    search_payers: ->(_seed) { [ [ "TEST" ], {} ] },
    search_practitioners: ->(seed) { [ [ seed[:practitioner_search_query] ], {} ] },
    store_text: lambda do |seed|
      [ [], { case_token: seed[:case_token], kind: :note, text: seed[:stored_text] } ]
    end,
    submit_claim: ->(_seed) { [ [ { service_code: "99213", amount: 100.0 } ], {} ] },
    update_obligation_status: ->(seed) { [ [ seed[:obligation_identifier] ], { status: "PENDING" } ] },
    update_referral: ->(seed) { [ [ seed[:referral_identifier], { status: "active" } ], {} ] },
    verify_eligibility: lambda do |seed|
      [ [ seed[:patient_identifier], seed[:coverage_resource_type] ], {} ]
    end,
    verify_identity_documents: ->(seed) { [ [ seed[:patient_identifier] ], {} ] },
    verify_residency: ->(seed) { [ [ seed[:patient_identifier] ], {} ] },
    verify_tribal_enrollment: ->(seed) { [ [ seed[:patient_identifier] ], {} ] }
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

      define_method(:test_contract_unknown_identifier_policy_exhaustive) do
        validate_contract_hooks!
        accounted = (
          AdapterContractTests::UNKNOWN_IDENTIFIER_RULES.keys |
          AdapterContractTests::NO_IDENTIFIER_METHODS |
          AdapterContractTests::DECLINED_UNKNOWN_IDENTIFIER_CHECKS.keys
        ).sort
        missing = base_methods - accounted
        assert_empty missing,
                     "every Base public method must appear in UNKNOWN_IDENTIFIER_RULES, " \
                     "NO_IDENTIFIER_METHODS, or DECLINED_UNKNOWN_IDENTIFIER_CHECKS; missing: #{missing.inspect}"
        unknown = accounted - base_methods
        assert_empty unknown,
                     "unknown identifier policy lists methods that are not Base public API: #{unknown.inspect}"
      end

      base_methods.each do |method_name|
        define_method(:"test_contract_#{method_name}") do
          validate_contract_hooks!
          seed = contract_seed!
          validate_required_seed_keys!(seed)
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

    def contract_fail_closed_stubs
      {}
    end

    def validate_contract_hooks!
      validate_contract_unsupported!
      validate_contract_fail_closed_stubs!
    end

    def validate_required_seed_keys!(seed)
      missing = REQUIRED_SEED_KEYS.select { |key| seed[key].nil? }
      return if missing.empty?

      flunk("contract seed is missing required key(s): #{missing.map(&:inspect).join(', ')}")
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

    def validate_contract_fail_closed_stubs!
      return if @contract_fail_closed_stubs_validated

      base_methods = Corvid::Adapters::Base.public_instance_methods(false)
      stubs = contract_fail_closed_stubs
      unsupported = contract_unsupported
      assert stubs.is_a?(Hash), "contract_fail_closed_stubs must be a Hash"

      stubs.each do |method_name, reason|
        assert base_methods.include?(method_name),
               "contract_fail_closed_stubs key #{method_name.inspect} is not a Base public method"
        assert reason.is_a?(String) && !reason.strip.empty?,
               "contract_fail_closed_stubs[#{method_name.inspect}] must be a non-empty String reason"
        refute unsupported.key?(method_name),
               "contract_fail_closed_stubs must be disjoint from contract_unsupported; " \
               "both list #{method_name.inspect}"
      end

      @contract_fail_closed_stubs_validated = true
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
      result = invoke_contract(method_name, seed)

      assert_implemented_shape(method_name, result, seed)
      if contract_fail_closed_stubs.key?(method_name)
        assert_fail_closed_stub_seeded_outcome(method_name, result)
      else
        assert_documented_seeded_outcome(method_name, result, seed)
      end
      assert_seeded_data_for_method(method_name, seed)
      assert_unknown_identifier_behavior(method_name, seed)
    end

    def assert_fail_closed_stub_seeded_outcome(method_name, result)
      case method_name
      when :refund_payment
        assert_refund_not_success(result)
      when :submit_claim
        assert_billing_mutation_fail_closed(result, id_key: :claim_identifier)
      when :process_payment
        assert_billing_mutation_fail_closed(result, id_key: :payment_identifier)
      when :check_claim_status
        assert_check_claim_status_fail_closed(result)
      when :check_eligibility_detailed
        assert_eligibility_detailed_unknown(result)
      else
        flunk("add assert_fail_closed_stub_seeded_outcome case for #{method_name}")
      end
    end

    def assert_billing_mutation_fail_closed(value, id_key:)
      assert_instance_of Hash, value
      assert_keys(value, [ id_key, :status ])
      identifier = value[id_key]
      status = value[:status]
      assert identifier.nil?, "fail-closed stub must not assign #{id_key}, got #{identifier.inspect}"
      refute_includes %w[accepted succeeded processing refunded], status.to_s.downcase,
                      "fail-closed stub must not report billing success status, got #{status.inspect}"
    end

    def assert_check_claim_status_fail_closed(value)
      assert_instance_of Hash, value
      status = value[:status]
      refute_includes %w[paid succeeded accepted finalized], status.to_s.downcase,
                      "check_claim_status(seeded) fail-closed stub must not report paid success, " \
                      "got #{status.inspect}"
    end

    def assert_documented_seeded_outcome(method_name, result, seed)
      case method_name
      when :verify_tribal_enrollment
        assert result[:enrolled], "verify_tribal_enrollment(seeded) must report enrolled: true"
        assert_equal :verified, result[:confidence],
                     "verify_tribal_enrollment(seeded) must report confidence :verified"
      when :verify_residency
        assert result[:on_reservation], "verify_residency(seeded) must report on_reservation: true"
      when :verify_identity_documents
        %i[ssn_present dob_present birthplace_present].each do |key|
          assert result[key], "verify_identity_documents(seeded) must have #{key}: true"
        end
      when :update_referral
        assert_equal true, result, "update_referral(seeded) must return true"
      when :create_obligation, :release_obligation, :record_payment, :update_obligation_status
        assert_open_struct_success(result, method_name)
      when :refund_payment
        assert_refund_success(result)
      end
    end

    def assert_open_struct_success(result, method_name)
      assert_open_struct_result(result)
      assert result.success?, "#{method_name}(seeded) must succeed per adapter contract"
    end

    def assert_refund_success(result)
      assert_instance_of Hash, result
      status = result[:status]
      assert AdapterContractTests::REFUND_SUCCESS_STATUSES.include?(status.to_s.downcase),
             "refund_payment(seeded) must report success status per base.rb, got #{status.inspect}"
    end

    def assert_seeded_data_for_method(method_name, seed)
      adapter = contract_adapter

      case method_name
      when :find_patient
        ref = adapter.find_patient(seed[:patient_identifier])
        assert_instance_of Corvid::PatientReference, ref
        assert_equal seed[:patient_identifier], ref.identifier
      when :find_practitioner
        ref = adapter.find_practitioner(seed[:practitioner_identifier])
        assert_instance_of Corvid::PractitionerReference, ref
        assert_equal seed[:practitioner_identifier], ref.identifier
      when :find_referral
        ref = adapter.find_referral(seed[:referral_identifier])
        assert_instance_of Corvid::ReferralReference, ref
        assert_equal seed[:referral_identifier], ref.identifier
      when :search_patients
        ids = adapter.search_patients(seed[:patient_search_query]).map(&:identifier)
        assert_includes ids, seed[:patient_identifier],
                        "search_patients(#{seed[:patient_search_query].inspect}) must include seeded patient"
      when :search_practitioners
        ids = adapter.search_practitioners(seed[:practitioner_search_query]).map(&:identifier)
        assert_includes ids, seed[:practitioner_identifier],
                        "search_practitioners(#{seed[:practitioner_search_query].inspect}) must include seeded practitioner"
      when :list_referrals
        ids = adapter.list_referrals(seed[:patient_identifier]).map(&:identifier)
        assert_includes ids, seed[:referral_identifier],
                        "list_referrals must include seeded referral #{seed[:referral_identifier].inspect}"
      when :fetch_text
        assert_equal seed[:stored_text], adapter.fetch_text(seed[:text_token])
      when :get_obligation
        if seed[:obligation_seeded]
          assert adapter.get_obligation(seed[:obligation_identifier]),
                 "get_obligation must return seeded obligation for #{seed[:obligation_identifier].inspect}"
        end
      when :get_obligation_by_referral
        if seed[:obligation_seeded]
          assert adapter.get_obligation_by_referral(seed[:referral_identifier]),
                 "get_obligation_by_referral must return seeded obligation for #{seed[:referral_identifier].inspect}"
        end
      when :get_care_team
        if seed[:care_team_seeded]
          refute_empty adapter.get_care_team(seed[:patient_identifier]),
                       "get_care_team must be non-empty when care_team_seeded"
        end
      when :list_claims
        if seed[:claims_listable]
          refute_empty adapter.list_claims(seed[:patient_identifier]),
                       "list_claims must be non-empty when claims_listable"
        end
      when :dereference_many
        known = seed[:dereference_tokens]
        result = adapter.dereference_many(known + [ AdapterContractTests::UNKNOWN_TEXT_TOKEN ])
        known.each do |token|
          assert result.key?(token), "dereference_many must include entry for known token #{token.inspect}"
          refute_nil result[token], "dereference_many must resolve known token #{token.inspect}"
          assert_instance_of Hash, result[token], "dereference_many values must be Hashes"
        end
      when :verify_eligibility
        assert_coverage_resource_type_guards(seed) unless eligibility_guards_skipped?
      when :check_eligibility_detailed
        unless eligibility_guards_skipped?
          wrong_payer = adapter.check_eligibility_detailed(
            seed[:patient_identifier],
            seed[:unknown_payer_identifier]
          )
          assert_eligibility_detailed_unknown(wrong_payer)
        end
      when :verify_tribal_enrollment
        if seed[:patient_identifier_tribal_no_confidence]
          result = adapter.verify_tribal_enrollment(seed[:patient_identifier_tribal_no_confidence])
          assert_tribal_enrollment_shape(result)
          refute_equal :verified, result[:confidence],
                       "tribal enrollment without confidence must not be :verified"
        end
      end
    end

    def eligibility_guards_skipped?
      unsupported = contract_unsupported
      unsupported.key?(:verify_eligibility) && unsupported.key?(:check_eligibility_detailed)
    end

    def assert_coverage_resource_type_guards(seed)
      adapter = contract_adapter
      match = adapter.verify_eligibility(seed[:patient_identifier], seed[:coverage_resource_type])
      assert_instance_of Hash, match
      assert_equal true, match[:eligible],
                   "verify_eligibility(#{seed[:coverage_resource_type].inspect}) must return eligible: true"

      wrong_type = adapter.verify_eligibility(seed[:patient_identifier], seed[:other_resource_type])
      assert_wrong_coverage_ineligible(wrong_type)

      unknown_payer = adapter.check_eligibility_detailed(
        seed[:patient_identifier],
        seed[:unknown_payer_identifier]
      )
      assert_eligibility_detailed_unknown(unknown_payer)
    end

    def assert_wrong_coverage_ineligible(result)
      return if result.nil?

      assert_instance_of Hash, result
      refute_equal true, result[:eligible],
                   "verify_eligibility(wrong resource type) must not return eligible: true"
    end

    def assert_unknown_identifier_behavior(method_name, seed)
      return if AdapterContractTests::NO_IDENTIFIER_METHODS.include?(method_name)
      return if AdapterContractTests::DECLINED_UNKNOWN_IDENTIFIER_CHECKS.key?(method_name)
      unless AdapterContractTests::UNKNOWN_IDENTIFIER_RULES.key?(method_name)
        flunk("no unknown-identifier behavior for #{method_name}")
      end

      adapter = contract_adapter

      case method_name
      when :find_patient
        assert_nil adapter.find_patient(seed[:unknown_patient_identifier])
      when :find_practitioner
        assert_nil adapter.find_practitioner(seed[:unknown_practitioner_identifier])
      when :find_referral
        assert_nil adapter.find_referral(seed[:unknown_referral_identifier])
      when :search_patients, :search_practitioners, :search_payers
        empty = adapter.public_send(method_name, AdapterContractTests::UNKNOWN_QUERY)
        assert_equal [], empty
      when :list_referrals, :list_claims
        assert_equal [], adapter.public_send(method_name, seed[:unknown_patient_identifier])
      when :get_care_team, :get_conditions, :get_medications, :get_coverages
        assert_equal [], adapter.public_send(method_name, seed[:unknown_patient_identifier])
      when :get_obligation
        assert_nil adapter.get_obligation(seed[:unknown_obligation_identifier])
      when :get_obligation_by_referral
        assert_nil adapter.get_obligation_by_referral(seed[:unknown_referral_identifier])
      when :get_payments
        assert_equal [], adapter.get_payments(obligation_id: seed[:unknown_obligation_identifier])
      when :fetch_text
        assert_nil adapter.fetch_text(AdapterContractTests::UNKNOWN_TEXT_TOKEN)
      when :dereference
        assert_nil adapter.dereference(seed[:unknown_patient_identifier])
      when :dereference_many
        result = adapter.dereference_many([ seed[:unknown_patient_identifier] ])
        assert_equal({}, result)
      when :check_claim_status
        result = adapter.check_claim_status(AdapterContractTests::UNKNOWN_CLAIM_IDENTIFIER)
        assert result.nil?, "check_claim_status(unknown) must be nil, got #{result.inspect}"
      when :update_referral
        refute adapter.update_referral(seed[:unknown_referral_identifier], { status: "active" })
      when :release_obligation
        result = adapter.release_obligation(seed[:unknown_obligation_identifier])
        assert_mutation_failure(result)
      when :update_obligation_status
        result = adapter.update_obligation_status(seed[:unknown_obligation_identifier], status: "PENDING")
        assert_mutation_failure(result)
      when :record_payment
        result = adapter.record_payment(
          obligation_id: seed[:unknown_obligation_identifier],
          amount: 1.0,
          payment_date: Date.new(2026, 1, 1)
        )
        assert record_payment_unknown_failure?(result),
               "record_payment(unknown obligation) must fail closed, got #{result.inspect}"
      when :refund_payment
        result = adapter.refund_payment(seed[:unknown_payment_identifier])
        assert_refund_not_success(result)
      when :verify_eligibility
        result = adapter.verify_eligibility(seed[:unknown_patient_identifier], seed[:coverage_resource_type])
        assert_verify_eligibility_unknown(result)
      when :check_eligibility_detailed
        result = adapter.check_eligibility_detailed(seed[:unknown_patient_identifier], seed[:payer_identifier])
        assert_eligibility_detailed_unknown(result)
      when :verify_tribal_enrollment
        result = adapter.verify_tribal_enrollment(seed[:unknown_patient_identifier])
        assert_tribal_enrollment_unknown(result)
      when :verify_identity_documents
        result = adapter.verify_identity_documents(seed[:unknown_patient_identifier])
        assert_identity_documents_unknown(result)
      when :verify_residency
        result = adapter.verify_residency(seed[:unknown_patient_identifier])
        assert_residency_unknown(result)
      end
    end

    def assert_mutation_failure(result)
      if result == true || result == false
        refute result, "mutation on unknown identifier must return false"
      elsif result.nil?
        assert_nil result
      else
        assert result.respond_to?(:success?), "expected OpenStruct-like result with success?"
        refute result.success?, "mutation on unknown identifier must not succeed"
      end
    end

    def record_payment_unknown_failure?(result)
      return true if result.nil?

      if result.respond_to?(:success?)
        !result.success?
      else
        false
      end
    end

    def assert_refund_not_success(result)
      assert_instance_of Hash, result
      status = result[:status]
      refute AdapterContractTests::REFUND_SUCCESS_STATUSES.include?(status.to_s.downcase),
             "refund_payment(unknown) must not report success status, got #{status.inspect}"
      refute status == true, "refund_payment(unknown) must not report success status"
    end

    def assert_verify_eligibility_unknown(result)
      return if result.nil?

      assert_instance_of Hash, result
      refute_equal true, result[:eligible], "verify_eligibility(unknown) must not return eligible: true"
    end

    def assert_eligibility_detailed_unknown(result)
      return if result.nil?

      assert_instance_of Hash, result
      refute_equal true, result[:eligible], "check_eligibility_detailed(unknown payer) must not return eligible: true"
    end

    def assert_tribal_enrollment_unknown(result)
      assert_instance_of Hash, result
      refute result[:enrolled], "verify_tribal_enrollment(unknown) must have enrolled: false"
      refute_equal :verified, result[:confidence],
                   "verify_tribal_enrollment(unknown) must not have confidence :verified"
    end

    def assert_identity_documents_unknown(result)
      assert_instance_of Hash, result
      %i[ssn_present dob_present birthplace_present].each do |key|
        refute result[key], "verify_identity_documents(unknown) must have #{key}: false"
      end
    end

    def assert_residency_unknown(result)
      assert_instance_of Hash, result
      refute result[:on_reservation], "verify_residency(unknown) must have on_reservation: false"
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
        assert_array_of_hashes(result)
      when :list_referrals
        assert_array_of(result, Corvid::ReferralReference)
      when :list_claims
        assert_array_of(result, Corvid::ClaimLineReference)
      when :create_referral, :store_text
        assert_token(result)
      when :update_referral
        assert_boolean(result)
      when :fetch_text
        assert result.is_a?(String), "fetch_text must return stored String for seeded token"
        refute_empty result
      when :dereference
        assert result.is_a?(Hash), "dereference must return Hash for known patient token"
      when :dereference_many
        assert_instance_of Hash, result
        result.each_value do |value|
          assert_instance_of Hash, value, "dereference_many values must be Hashes per base.rb"
        end
      when :get_budget_summary, :get_site_params, :get_obligation_summary
        assert_instance_of Hash, result
      when :get_obligations, :get_outstanding_obligations
        assert_instance_of Array, result
        result.each { |element| assert_instance_of Hash, element }
      when :get_payments, :fetch_remittances
        assert_instance_of Array, result
        result.each { |element| assert_instance_of Hash, element }
      when :get_obligation, :get_obligation_by_referral
        if seed[:obligation_seeded]
          assert_instance_of Hash, result
        else
          assert result.nil? || result.is_a?(Hash), "obligation lookup must be Hash or nil"
        end
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
        assert_billing_mutation_shape(result, id_key: :claim_identifier)
      when :check_claim_status
        assert_check_claim_status_shape(result)
      when :check_eligibility_detailed
        assert_keys(result, %i[eligible])
        assert_includes [ true, false ], result[:eligible]
      when :process_payment
        assert_billing_mutation_shape(result, id_key: :payment_identifier)
      when :refund_payment
        assert_billing_mutation_shape(result, id_key: :refund_identifier)
      else
        flunk("no shape assertion for implemented method #{method_name}")
      end
    end

    def assert_array_of(value, element_class)
      assert_instance_of Array, value
      value.each { |element| assert_instance_of element_class, element }
    end

    def assert_array_of_hashes(value)
      assert_instance_of Array, value
      value.each { |element| assert_instance_of Hash, element }
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
      assert_keys(value, %i[
                    enrolled membership_number tribe_name tribe_code member_status blood_quantum
                    confidence verified_at
                  ])
      assert_includes [ true, false ], value[:enrolled]
      assert_optional_string(value[:membership_number])
      assert_optional_string(value[:tribe_name])
      assert_optional_string(value[:tribe_code])
      assert_optional_string(value[:member_status])
      assert value[:blood_quantum].nil? || value[:blood_quantum].is_a?(Hash),
             "blood_quantum must be Hash or nil per base.rb, got #{value[:blood_quantum].class}"
      assert_includes %i[verified stale unavailable], value[:confidence]
      assert_time_like(value[:verified_at])
    end

    def assert_identity_documents_shape(value)
      assert_instance_of Hash, value
      assert_keys(value, %i[ssn_present dob_present birthplace_present verified_at])
      %i[ssn_present dob_present birthplace_present].each do |key|
        assert_includes [ true, false ], value[key]
      end
      assert_time_like(value[:verified_at])
    end

    def assert_residency_shape(value)
      assert_instance_of Hash, value
      assert_keys(value, %i[on_reservation address service_area verified_at])
      assert_includes [ true, false ], value[:on_reservation]
      assert_optional_string(value[:address])
      assert_optional_string(value[:service_area])
      assert_time_like(value[:verified_at])
    end

    def assert_check_claim_status_shape(value)
      assert_instance_of Hash, value
      assert_keys(value, %i[status paid_amount adjustment_amount paid_date])
      assert_optional_string(value[:status])
      assert_optional_numeric(value[:paid_amount])
      assert_optional_numeric(value[:adjustment_amount])
      paid_date = value[:paid_date]
      assert paid_date.nil? || paid_date.is_a?(Date),
             "paid_date must be Date or nil per base.rb, got #{paid_date.class}"
    end

    def assert_billing_mutation_shape(value, id_key:)
      assert_instance_of Hash, value
      assert_keys(value, [ id_key, :status ])
      identifier = value[id_key]
      status = value[:status]
      assert identifier.nil? || identifier.is_a?(String),
             "#{id_key} must be String or nil"
      assert status.nil? || status.is_a?(String), "status must be String or nil"
      if identifier.nil?
        refute_includes %w[accepted succeeded processing refunded], status.to_s.downcase,
                        "non-success status required when #{id_key} is nil"
      end
    end

    def assert_optional_string(value)
      assert value.nil? || value.is_a?(String), "expected String or nil, got #{value.class}"
    end

    def assert_optional_numeric(value)
      return if value.nil?

      assert value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(BigDecimal),
             "expected Numeric or nil, got #{value.class}"
    end

    def assert_time_like(value)
      assert value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone) || value.is_a?(DateTime),
             "verified_at must be Time, ActiveSupport::TimeWithZone, or DateTime, got #{value.class}"
    end
  end
end
