# frozen_string_literal: true

require "active_support/testing/time_helpers"
require "corvid/adapters/base"
require "corvid/value_objects"

# Shared behavior contract for Corvid::Adapters::Base implementations.
# Including classes must define contract_adapter, contract_seed! (taking
# coverage_answer_as_of:, the source answer time to seed on the active
# coverage, nil for none), and contract_unsupported (Hash of method_name => reason). Optional
# contract_fail_closed_stubs documents methods that return a fail-closed
# stub instead of raising (Hash of method_name => reason, default {}).
#
# Every seeded check runs for every implemented method. An adapter that
# cannot serve one lists the method in contract_unsupported (it must then
# raise NotImplementedError); there are no seed flags that skip checks.
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
    payer_search_query
    coverage_resource_type
    other_resource_type
    inactive_coverage_resource_type
    dereference_tokens
  ].freeze

  LIST_SEARCH_READS = %i[
    search_patients
    search_practitioners
    list_referrals
    list_claims
    get_care_team
  ].freeze

  # Stub transport on the contract adapter instance so list/search reads see a failed search.
  FHIR_SIMULATE_FAILED_LIST_SEARCH = lambda do |adapter|
    adapter.define_singleton_method(:fhir_search) { |*_args, **_kwargs| nil }
  end

  # Seed keys that used to switch seeded checks off. A seed that still
  # sends one is rejected: list the method in contract_unsupported instead.
  RETIRED_SEED_FLAGS = %i[care_team_seeded claims_listable obligation_seeded].freeze

  # Seeded on the active coverage so every adapter must carry a known
  # source answer time through, not only report nil.
  KNOWN_COVERAGE_ANSWER_AS_OF = Time.utc(2026, 3, 15, 9, 0, 0)
  COVERAGE_ANSWER_READS = %i[get_coverages verify_eligibility].freeze

  UPDATED_REFERRAL_STATUS = "on-hold"
  UPDATED_OBLIGATION_STATUS = "PARTIAL"
  RECORDED_PAYMENT_AMOUNT = 1.0

  REFUND_SUCCESS_STATUSES = %w[refunded succeeded].freeze

  # verify_eligibility must not answer from an arbitrary coverage when the
  # requested resource type is missing or blank (ADR 0005).
  BLANK_VERIFY_ELIGIBILITY_RESOURCE_TYPES = [
    nil,
    "",
    "   ",
    "\t \n",
    :""
  ].freeze

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
    get_conditions: "unknown patient yields empty array, or nil when the source cannot answer",
    get_coverages: "unknown patient yields empty array",
    get_medications: "unknown patient yields empty array, or nil when the source cannot answer",
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
    verify_tribal_enrollment: "unknown patient is enrolled nil (undetermined), never :verified confidence"
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
      [
        [],
        {
          obligation_id: seed[:obligation_identifier],
          amount: AdapterContractTests::RECORDED_PAYMENT_AMOUNT,
          payment_date: Date.new(2026, 1, 1)
        }
      ]
    end,
    refund_payment: ->(seed) { [ [ seed[:payment_identifier] ], {} ] },
    release_obligation: ->(seed) { [ [ seed[:obligation_identifier] ], {} ] },
    search_patients: ->(seed) { [ [ seed[:patient_search_query] ], {} ] },
    search_payers: ->(seed) { [ [ seed[:payer_search_query] ], {} ] },
    search_practitioners: ->(seed) { [ [ seed[:practitioner_search_query] ], {} ] },
    store_text: lambda do |seed|
      [ [], { case_token: seed[:case_token], kind: :note, text: seed[:stored_text] } ]
    end,
    submit_claim: ->(_seed) { [ [ { service_code: "99213", amount: 100.0 } ], {} ] },
    update_obligation_status: lambda do |seed|
      [ [ seed[:obligation_identifier] ], { status: AdapterContractTests::UPDATED_OBLIGATION_STATUS } ]
    end,
    update_referral: lambda do |seed|
      [ [ seed[:referral_identifier], { status: AdapterContractTests::UPDATED_REFERRAL_STATUS } ], {} ]
    end,
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
      include ActiveSupport::Testing::TimeHelpers
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

      define_method(:test_contract_coverage_answer_as_of_known_time) do
        validate_contract_hooks!
        reads = AdapterContractTests::COVERAGE_ANSWER_READS.reject { |m| contract_unsupported.key?(m) }
        next if reads.empty?

        seed = contract_seed_with_known_answer_time!
        assert_seeded_known_answer_time(reads, seed)
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

    def contract_declined_list_read_failed_search
      {}
    end

    def validate_contract_hooks!
      validate_contract_unsupported!
      validate_contract_fail_closed_stubs!
      validate_contract_declined_list_read_failed_search!
    end

    def validate_required_seed_keys!(seed)
      retired = RETIRED_SEED_FLAGS.select { |key| seed.key?(key) }
      unless retired.empty?
        flunk("contract seed sends retired flag(s) #{retired.map(&:inspect).join(', ')}; seed flags " \
              "cannot switch checks off. List the method in contract_unsupported with a reason instead")
      end

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

    def validate_contract_declined_list_read_failed_search!
      return if @contract_declined_list_read_failed_search_validated

      base_methods = Corvid::Adapters::Base.public_instance_methods(false)
      declined = contract_declined_list_read_failed_search
      assert declined.is_a?(Hash), "contract_declined_list_read_failed_search must be a Hash"

      declined.each do |method_name, reason|
        assert AdapterContractTests::LIST_SEARCH_READS.include?(method_name),
               "contract_declined_list_read_failed_search key #{method_name.inspect} must be a list/search read"
        assert base_methods.include?(method_name),
               "contract_declined_list_read_failed_search key #{method_name.inspect} is not a Base public method"
        assert reason.is_a?(String) && !reason.strip.empty?,
               "contract_declined_list_read_failed_search[#{method_name.inspect}] must be a non-empty String reason"
      end

      @contract_declined_list_read_failed_search_validated = true
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
      before = contract_state_before(method_name, seed)
      result = invoke_contract(method_name, seed)

      assert_implemented_shape(method_name, result, seed)
      if contract_fail_closed_stubs.key?(method_name)
        assert_fail_closed_stub_seeded_outcome(method_name, result)
      else
        assert_documented_seeded_outcome(method_name, result, seed)
        assert_write_read_back(method_name, result, seed, before)
      end
      assert_seeded_data_for_method(method_name, seed)
      assert_unknown_identifier_behavior(method_name, seed)
      assert_list_read_failed_search_unknown(method_name, seed) if LIST_SEARCH_READS.include?(method_name)
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
      when :search_payers
        assert_equal [], result, "search_payers fail-closed stub must not invent payers"
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
      when :check_eligibility_detailed
        assert_equal true, result[:eligible],
                     "check_eligibility_detailed(seeded patient, seeded payer) must return eligible: true"
      when :submit_claim
        assert_billing_mutation_success(result, :claim_identifier, method_name)
      when :process_payment
        assert_billing_mutation_success(result, :payment_identifier, method_name)
      end
    end

    def assert_billing_mutation_success(result, id_key, method_name)
      assert_token(result[id_key])
      refute_includes %w[failed rejected denied error unsupported not_found], result[:status].to_s.downcase,
                      "#{method_name}(seeded) must not report a failure status, got #{result[:status].inspect}"
    end

    # Snapshot taken before the seeded call, so a write can be shown to
    # have changed something.
    def contract_state_before(method_name, seed)
      case method_name
      when :release_obligation, :update_obligation_status
        contract_adapter.get_obligation(seed[:obligation_identifier])&.dup
      when :record_payment
        contract_adapter.get_payments(obligation_id: seed[:obligation_identifier]).dup
      end
    end

    # A write that reports success must be visible to the matching read.
    def assert_write_read_back(method_name, result, seed, before)
      adapter = contract_adapter

      case method_name
      when :create_referral
        assert_created_referral_readable(result, seed)
      when :store_text
        assert_equal seed[:stored_text], adapter.fetch_text(result),
                     "fetch_text must return the text store_text stored under the returned token"
      when :update_referral
        ref = adapter.find_referral(seed[:referral_identifier])
        assert_equal AdapterContractTests::UPDATED_REFERRAL_STATUS, ref&.status,
                     "update_referral reported success but find_referral does not show the new status"
      when :create_obligation
        assert_instance_of Hash, adapter.get_obligation(result.id),
                           "create_obligation id #{result.id.inspect} must be readable with get_obligation"
      when :update_obligation_status
        obligation = adapter.get_obligation(seed[:obligation_identifier])
        assert_equal AdapterContractTests::UPDATED_OBLIGATION_STATUS, obligation&.dig(:status),
                     "update_obligation_status reported success but get_obligation shows no change"
      when :release_obligation
        assert_obligation_released(seed[:obligation_identifier], before)
      when :record_payment
        assert_payment_recorded(seed[:obligation_identifier], before)
      when :submit_claim
        status = adapter.check_claim_status(result[:claim_identifier])
        assert_instance_of Hash, status, "check_claim_status must find the claim submit_claim returned"
        assert_check_claim_status_shape(status)
      when :process_payment
        assert_refund_success(adapter.refund_payment(result[:payment_identifier]))
      end
    end

    def assert_created_referral_readable(token, seed)
      adapter = contract_adapter
      ref = adapter.find_referral(token)
      assert_instance_of Corvid::ReferralReference, ref,
                         "create_referral token #{token.inspect} must be findable with find_referral"
      assert_equal token, ref.identifier
      assert_equal seed[:patient_identifier], ref.patient_identifier,
                   "created referral must belong to the patient it was created for"
      assert_includes adapter.list_referrals(seed[:patient_identifier]).map(&:identifier), token,
                      "list_referrals must include the referral create_referral returned"
    end

    def assert_obligation_released(obligation_identifier, before)
      adapter = contract_adapter
      after = adapter.get_obligation(obligation_identifier)
      assert_instance_of Hash, after, "a released obligation must still be readable"
      refute_equal before&.dig(:status), after[:status],
                   "release_obligation reported success but the obligation status did not change"
      refute_includes adapter.get_outstanding_obligations.map { |o| o[:id] }, obligation_identifier,
                      "a released obligation must not be outstanding"
    end

    def assert_payment_recorded(obligation_identifier, before)
      payments = contract_adapter.get_payments(obligation_id: obligation_identifier)
      assert_equal before.size + 1, payments.size,
                   "record_payment reported success but get_payments did not gain a payment"
      assert payments.any? { |payment| payment[:amount].to_f == AdapterContractTests::RECORDED_PAYMENT_AMOUNT },
             "get_payments must include the recorded amount"
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
        obligation = adapter.get_obligation(seed[:obligation_identifier])
        assert_instance_of Hash, obligation,
                           "get_obligation must return seeded obligation for #{seed[:obligation_identifier].inspect}"
        assert_equal seed[:obligation_identifier], obligation[:id],
                     "get_obligation must return the seeded obligation, not another record"
      when :get_obligation_by_referral
        obligation = adapter.get_obligation_by_referral(seed[:referral_identifier])
        assert_instance_of Hash, obligation,
                           "get_obligation_by_referral must return seeded obligation for " \
                           "#{seed[:referral_identifier].inspect}"
        assert_equal seed[:obligation_identifier], obligation[:id],
                     "get_obligation_by_referral must return the obligation seeded for that referral"
      when :get_care_team
        members = adapter.get_care_team(seed[:patient_identifier])
        assert_includes members.map(&:practitioner_identifier), seed[:practitioner_identifier],
                        "get_care_team must include the seeded practitioner"
      when :list_claims
        assert_seeded_claim_lines(seed)
      when :search_payers
        # A fail-closed stub has no directory; its seeded outcome is [].
        return if contract_fail_closed_stubs.key?(:search_payers)

        payers = adapter.search_payers(seed[:payer_search_query])
        assert_includes payers.map { |payer| payer[:payer_identifier] }, seed[:payer_identifier],
                        "search_payers(#{seed[:payer_search_query].inspect}) must include the seeded payer"
      when :dereference
        assert_patient_dereference(seed)
      when :dereference_many
        known = seed[:dereference_tokens]
        result = adapter.dereference_many(known + [ AdapterContractTests::UNKNOWN_TEXT_TOKEN ])
        known.each do |token|
          assert result.key?(token), "dereference_many must include entry for known token #{token.inspect}"
          refute_nil result[token], "dereference_many must resolve known token #{token.inspect}"
          assert_instance_of Hash, result[token], "dereference_many values must be Hashes"
          assert_equal adapter.dereference(token), result[token],
                       "dereference_many must return the same record as dereference for #{token.inspect}"
        end
      when :get_coverages
        assert_get_coverages_answer_as_of_policy(seed)
      when :verify_eligibility
        assert_coverage_resource_type_guards(seed)
        assert_eligibility_inquiry_date_contract(adapter, seed, method: :verify_eligibility)
        assert_verify_eligibility_answer_as_of_policy(seed)
      when :check_eligibility_detailed
        wrong_payer = adapter.check_eligibility_detailed(
          seed[:patient_identifier],
          seed[:unknown_payer_identifier]
        )
        assert_eligibility_detailed_unknown(wrong_payer)
        assert_eligibility_inquiry_date_contract(adapter, seed, method: :check_eligibility_detailed)
      when :verify_tribal_enrollment
        if seed[:patient_identifier_tribal_no_confidence]
          result = adapter.verify_tribal_enrollment(seed[:patient_identifier_tribal_no_confidence])
          assert_tribal_enrollment_shape(result)
          refute_equal :verified, result[:confidence],
                       "tribal enrollment without confidence must not be :verified"
        end
      end
    end

    def assert_seeded_claim_lines(seed)
      lines = contract_adapter.list_claims(seed[:patient_identifier])
      assert_includes lines.map(&:claim_identifier), seed[:claim_identifier],
                      "list_claims must include a line from the seeded claim"
      lines.each do |line|
        assert_equal seed[:patient_identifier], line.patient_identifier,
                     "list_claims must return only the requested patient's lines"
      end
    end

    def assert_patient_dereference(seed)
      adapter = contract_adapter
      record = adapter.dereference(seed[:patient_identifier])
      assert_instance_of Hash, record
      display_name = adapter.find_patient(seed[:patient_identifier]).display_name
      assert_includes record.values, display_name,
                      "dereference(seeded patient) must return that patient's record"
    end

    def contract_seed_with_known_answer_time!
      unless method(:contract_seed!).parameters.include?([ :key, :coverage_answer_as_of ])
        flunk("contract_seed! must take coverage_answer_as_of: and seed it on the active coverage")
      end

      known = AdapterContractTests::KNOWN_COVERAGE_ANSWER_AS_OF
      seed = contract_seed!(coverage_answer_as_of: known)
      validate_required_seed_keys!(seed)
      seed.merge(coverage_answer_as_of: known)
    end

    def assert_seeded_known_answer_time(reads, seed)
      # An adapter whose get_coverages returns [] (FhirAdapter) has no row to check.
      assert_get_coverages_answer_as_of_policy(seed) if reads.include?(:get_coverages)
      assert_verify_eligibility_answer_as_of_policy(seed) if reads.include?(:verify_eligibility)
    end

    def expected_coverage_answer_as_of(seed)
      seed.fetch(:coverage_answer_as_of, nil)
    end

    def assert_coverage_answer_as_of_policy(seed)
      assert_get_coverages_answer_as_of_policy(seed)
      assert_verify_eligibility_answer_as_of_policy(seed)
    end

    def assert_get_coverages_answer_as_of_policy(seed)
      adapter = contract_adapter
      expected = expected_coverage_answer_as_of(seed)
      patient = seed[:patient_identifier]
      active_type = seed[:coverage_resource_type]
      inactive_type = seed[:inactive_coverage_resource_type]

      coverages = adapter.get_coverages(patient)
      assert_instance_of Array, coverages
      return if coverages.empty?

      active_rows = coverages.select { |row| coverage_row_resource_type(row) == active_type.to_s }
      refute_empty active_rows,
                   "get_coverages must include a row for coverage_resource_type #{active_type.inspect}"
      active_rows.each do |row|
        assert_expected_answer_as_of(row[:as_of], expected,
                                   "get_coverages active #{active_type.inspect} row must return the seeded answer time, nil when unset")
      end

      inactive_rows = coverages.select { |row| coverage_row_resource_type(row) == inactive_type.to_s }
      inactive_rows.each do |row|
        assert_nil row[:as_of],
                   "get_coverages inactive #{inactive_type.inspect} row must have nil :as_of when unset in seed"
      end
    end

    def assert_verify_eligibility_answer_as_of_policy(seed)
      adapter = contract_adapter
      expected = expected_coverage_answer_as_of(seed)
      patient = seed[:patient_identifier]
      active_type = seed[:coverage_resource_type]
      inactive_type = seed[:inactive_coverage_resource_type]

      match = adapter.verify_eligibility(patient, active_type)
      assert_instance_of Hash, match
      assert_expected_answer_as_of(match[:as_of], expected,
                                   "verify_eligibility(#{active_type.inspect}) must return the seeded answer time, nil when unset")

      inactive = adapter.verify_eligibility(patient, inactive_type)
      assert_instance_of Hash, inactive
      assert_nil inactive[:as_of],
                 "verify_eligibility(#{inactive_type.inspect}) must have nil :as_of when unset in seed"
    end

    def coverage_row_resource_type(row)
      if row.key?(:coverage_type)
        row[:coverage_type].to_s
      elsif row.key?(:resource_type)
        row[:resource_type].to_s
      else
        row["coverage_type"] || row["resource_type"]
      end.to_s
    end

    def assert_coverage_resource_type_guards(seed)
      adapter = contract_adapter

      AdapterContractTests::BLANK_VERIFY_ELIGIBILITY_RESOURCE_TYPES.each do |blank_type|
        result = adapter.verify_eligibility(seed[:patient_identifier], blank_type)
        assert_nil result,
                   "verify_eligibility(#{blank_type.inspect}) must be nil (undetermined), " \
                   "never a coverage answer, got #{result.inspect}"
      end

      match = adapter.verify_eligibility(seed[:patient_identifier], seed[:coverage_resource_type])
      assert_instance_of Hash, match
      assert_equal true, match[:eligible],
                   "verify_eligibility(#{seed[:coverage_resource_type].inspect}) must return eligible: true"

      wrong_type = adapter.verify_eligibility(seed[:patient_identifier], seed[:other_resource_type])
      assert_wrong_coverage_ineligible(wrong_type)

      inactive = adapter.verify_eligibility(seed[:patient_identifier], seed[:inactive_coverage_resource_type])
      assert_instance_of Hash, inactive,
                         "verify_eligibility(#{seed[:inactive_coverage_resource_type].inspect}) must answer " \
                         "for the seeded inactive coverage"
      assert_equal false, inactive[:eligible], "an inactive coverage must return eligible: false"
    end

    def assert_wrong_coverage_ineligible(result)
      return if result.nil?

      assert_instance_of Hash, result
      refute_equal true, result[:eligible],
                   "verify_eligibility(wrong resource type) must not return eligible: true"
    end

    def assert_list_read_failed_search_unknown(method_name, seed)
      return if contract_declined_list_read_failed_search.key?(method_name)

      simulator = seed[:simulate_failed_list_search]
      unless simulator.is_a?(Proc)
        flunk("contract seed must provide simulate_failed_list_search proc for #{method_name}, " \
              "or list the method in contract_declined_list_read_failed_search with a reason")
      end

      adapter = contract_adapter
      simulator.call(adapter)

      case method_name
      when :search_patients
        query = seed[:patient_search_query]
        result = adapter.search_patients(query)
      when :search_practitioners
        query = seed[:practitioner_search_query]
        result = adapter.search_practitioners(query)
      when :list_referrals, :list_claims, :get_care_team
        result = adapter.public_send(method_name, seed[:patient_identifier])
      else
        flunk("no failed-search unknown assertion for #{method_name}")
      end

      assert_nil result,
                 "#{method_name} must be nil (unknown) when underlying search fails, got #{result.inspect}"
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
      when :get_care_team, :get_coverages
        assert_equal [], adapter.public_send(method_name, seed[:unknown_patient_identifier])
      when :get_conditions, :get_medications
        # base.rb: nil is "unknown", [] is "none"; both fail closed.
        result = adapter.public_send(method_name, seed[:unknown_patient_identifier])
        assert result.nil? || result == [], "#{method_name}(unknown) must be nil or [], got #{result.inspect}"
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

    def assert_eligibility_inquiry_date_contract(adapter, seed, method:)
      saved_zone = Time.zone
      explicit_dos = Date.new(2026, 6, 15)
      args =
        case method
        when :verify_eligibility
          [ seed[:patient_identifier], seed[:coverage_resource_type] ]
        when :check_eligibility_detailed
          [ seed[:patient_identifier], seed[:payer_identifier] ]
        else
          flunk("unsupported eligibility inquiry date contract for #{method}")
        end

      explicit = adapter.public_send(method, *args, date_of_service: explicit_dos)
      assert_instance_of Hash, explicit, "#{method}(explicit date_of_service) must return a Hash"
      assert_keys(explicit, %i[date_of_service date_of_service_defaulted])
      assert_equal explicit_dos, explicit[:date_of_service]
      refute explicit[:date_of_service_defaulted], "#{method} must set date_of_service_defaulted false when DOS passed"

      defaulted = adapter.public_send(method, *args)
      assert_instance_of Hash, defaulted, "#{method}(default) must return a Hash"
      assert_keys(defaulted, %i[date_of_service date_of_service_defaulted])
      assert_instance_of Date, defaulted[:date_of_service]
      assert defaulted[:date_of_service_defaulted], "#{method} must set date_of_service_defaulted true when DOS omitted"

      [ "2026-06-15", Time.utc(2026, 6, 15, 12, 0, 0), DateTime.new(2026, 6, 15, 12, 0, 0) ].each do |invalid_dos|
        assert_raises(ArgumentError) do
          adapter.public_send(method, *args, date_of_service: invalid_dos)
        end
      end

      Time.zone = "Pacific/Kiritimati"
      travel_to Time.utc(2025, 12, 31, 12, 0, 0) do
        zoned = adapter.public_send(method, *args)
        assert_equal Date.current, zoned[:date_of_service],
                     "#{method} default date_of_service must be Date.current in Time.zone, not Date.today (issue #712)"
        refute_equal Date.today, zoned[:date_of_service] if Date.today != Date.current
      end
    ensure
      Time.zone = saved_zone
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
      assert_nil result[:enrolled], "verify_tribal_enrollment(unknown) must have enrolled: nil (unknown is not a denial)"
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
        assert_instance_of Hash, result
      when :create_obligation, :release_obligation, :record_payment, :update_obligation_status
        assert_open_struct_result(result)
      when :get_care_team
        assert_array_of(result, Corvid::CareTeamMemberReference)
      when :get_coverages
        assert_get_coverages_shape(result)
      when :get_conditions
        assert_clinical_read_shape(result, Corvid::ConditionReference)
      when :get_medications
        assert_clinical_read_shape(result, Corvid::MedicationReference)
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
        assert_keys(result, %i[eligible date_of_service date_of_service_defaulted])
        assert_includes [ true, false ], result[:eligible]
        assert_instance_of Date, result[:date_of_service]
        assert_includes [ true, false ], result[:date_of_service_defaulted]
      when :process_payment
        assert_billing_mutation_shape(result, id_key: :payment_identifier)
      when :refund_payment
        assert_billing_mutation_shape(result, id_key: :refund_identifier)
      else
        flunk("no shape assertion for implemented method #{method_name}")
      end
    end

    # base.rb: an Array of references, or nil when the source cannot answer.
    def assert_clinical_read_shape(value, element_class)
      return if value.nil?

      assert_array_of(value, element_class)
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

    def assert_get_coverages_shape(value)
      assert_instance_of Array, value
      value.each do |row|
        assert_instance_of Hash, row
        assert row.key?(:as_of), "get_coverages row must include :as_of"
        assert_answer_as_of(row[:as_of], context: "get_coverages row")
      end
    end

    def assert_expected_answer_as_of(actual, expected, message)
      if expected.nil?
        assert_nil actual, message
      else
        assert_equal expected, actual, message
      end
    end

    def assert_answer_as_of(value, context:)
      return if value.nil?

      assert value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone),
             "#{context} :as_of must be Time or ActiveSupport::TimeWithZone, got #{value.class}"
    end

    def assert_verify_eligibility_shape(value)
      return if value.nil?

      assert_instance_of Hash, value
      assert_keys(value, %i[date_of_service date_of_service_defaulted])
      assert_instance_of Date, value[:date_of_service]
      assert_includes [ true, false ], value[:date_of_service_defaulted]
      assert value.key?(:as_of), "verify_eligibility must include :as_of"
      assert_answer_as_of(value[:as_of], context: "verify_eligibility")
      # base.rb: these dates are Date or nil when present.
      %i[coverage_start coverage_end renewal_date].each do |key|
        next unless value.key?(key)

        assert value[key].nil? || value[key].is_a?(Date),
               "verify_eligibility #{key} must be a Date or nil, got #{value[key].class}"
      end
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
      # nil: the source could not answer (unreachable or unknown record).
      assert_includes [ true, false, nil ], value[:enrolled]
      assert_optional_string(value[:membership_number])
      assert_optional_string(value[:tribe_name])
      assert_optional_string(value[:tribe_code])
      assert_optional_string(value[:member_status])
      assert_blood_quantum_shape(value[:blood_quantum])
      assert_includes %i[verified stale unavailable], value[:confidence]
      assert_time_like(value[:verified_at])
    end

    # base.rb: { display: String, decimal: Float|nil } or nil.
    def assert_blood_quantum_shape(value)
      return if value.nil?

      assert_instance_of Hash, value, "blood_quantum must be a Hash or nil per base.rb"
      assert_equal %i[decimal display], value.keys.sort,
                   "blood_quantum must have exactly :display and :decimal, got #{value.keys.inspect}"
      assert_instance_of String, value[:display], "blood_quantum[:display] must be a String"
      refute_empty value[:display].strip, "blood_quantum[:display] must not be blank"
      decimal = value[:decimal]
      assert decimal.nil? || decimal.is_a?(Float),
             "blood_quantum[:decimal] must be a Float or nil, got #{decimal.class}"
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
      assert_instance_of String, value[:status], "check_claim_status must report a String status"
      refute_empty value[:status].strip, "check_claim_status must not report a blank status"
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
      # base.rb documents status: str, and callers persist it.
      assert_instance_of String, status, "#{id_key} result status must be a String"
      refute_empty status.strip, "#{id_key} result status must not be blank"
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
