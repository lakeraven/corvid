# frozen_string_literal: true

require "minitest/autorun"
require "corvid"
require "corvid/rcm"
require_relative "claim_factory"

# Typed eligibility inquiry/response shapes and small parsing rules for the
# clearinghouse seam (#736). Synthetic identifiers only.
class Corvid::Rcm::EligibilityTest < Minitest::Test
  Factory = Corvid::Rcm::ClaimFactory
  FIXED_CLOCK = -> { Time.utc(2026, 9, 1, 12, 0, 0) }

  MEMBER_ACTIVE_COMMERCIAL = "MBR-ACTIVE-COMMERCIAL"
  MEMBER_INACTIVE = "MBR-INACTIVE"
  MEMBER_MEDICAID_OPEN = "MBR-MEDICAID-OPEN"
  MEMBER_AAA72 = "MBR-AAA72"
  MEMBER_AAA42 = "MBR-AAA42"
  MEMBER_AAA_UNMAPPED = "MBR-AAA-UNMAPPED"
  MEMBER_UNKNOWN = "MBR-NOT-IN-FIXTURE-TABLE"
  MEMBER_MALFORMED_FIXTURE = "MBR-MALFORMED-FIXTURE"

  def inquiry(**overrides)
    Corvid::Rcm::EligibilityInquiry.new(**{
      patient_identifier: "pt_elig_0001",
      payer_identifier: "EXPAYER01",
      member_identifier: MEMBER_ACTIVE_COMMERCIAL,
      service_date: Factory::SERVICE_DATE,
      provider_npi: Factory::BILLING_NPI
    }.merge(overrides))
  end

  # -- value types -----------------------------------------------------------

  def test_eligibility_inquiry_is_a_data_object_with_the_required_members
    inquiry = self.inquiry(member_identifier: "MBR-SYNTH-01", service_type_codes: %w[30 98])

    assert_kind_of Data, inquiry
    assert_equal "pt_elig_0001", inquiry.patient_identifier
    assert_equal "EXPAYER01", inquiry.payer_identifier
    assert_equal "MBR-SYNTH-01", inquiry.member_identifier
    assert_equal Factory::SERVICE_DATE, inquiry.service_date
    assert_equal %w[30 98], inquiry.service_type_codes
    assert_equal Factory::BILLING_NPI, inquiry.provider_npi
  end

  def test_eligibility_inquiry_defaults_service_type_codes_to_health_benefit_plan_coverage
    inquiry = Corvid::Rcm::EligibilityInquiry.new(
      patient_identifier: "pt_elig_0002",
      payer_identifier: "EXPAYER01",
      member_identifier: "MBR-SYNTH-02",
      service_date: Factory::SERVICE_DATE,
      provider_npi: Factory::BILLING_NPI
    )

    assert_equal [ "30" ], inquiry.service_type_codes
  end

  def test_eligibility_response_rejects_an_outcome_outside_active_inactive_undetermined
    assert_raises(ArgumentError) do
      Corvid::Rcm::EligibilityResponse.new(
        outcome: :denied,
        plans: [],
        errors: [],
        as_of: FIXED_CLOCK.call,
        raw_reference: nil
      )
    end
  end

  def test_eligibility_plan_exposes_coverage_and_benefit_fields
    benefit = Corvid::Rcm::EligibilityBenefit.new(
      service_type_code: "30",
      code: "1",
      coverage_level: "IND",
      amount: BigDecimal("25.00"),
      percent: nil,
      in_network: true
    )
    plan = Corvid::Rcm::EligibilityPlan.new(
      payer_identifier: "EXPAYER01",
      plan_name: "SYNTHETIC PPO PLAN",
      group_number: "GRP-SYNTH-01",
      coverage_start: Date.new(2026, 1, 1),
      coverage_end: Date.new(2026, 12, 31),
      benefits: [ benefit ]
    )

    assert_equal "EXPAYER01", plan.payer_identifier
    assert_equal "SYNTHETIC PPO PLAN", plan.plan_name
    assert_equal "GRP-SYNTH-01", plan.group_number
    assert_equal Date.new(2026, 1, 1), plan.coverage_start
    assert_equal Date.new(2026, 12, 31), plan.coverage_end
    assert_equal "30", plan.benefits.first.service_type_code
    assert_equal "1", plan.benefits.first.code
    assert_equal "IND", plan.benefits.first.coverage_level
    assert_in_delta 25.00, plan.benefits.first.amount, 0.001
    assert_nil plan.benefits.first.percent
    assert plan.benefits.first.in_network
  end

  def test_eligibility_error_exposes_aaa_segment_fields
    error = Corvid::Rcm::EligibilityError.new(
      code: "72",
      description: "Invalid/Missing Subscriber/Insured ID",
      followup_action: "C"
    )

    assert_equal "72", error.code
    assert_match(/Subscriber/, error.description)
    assert_equal "C", error.followup_action
  end

  # -- placeholder end dates -------------------------------------------------

  def test_coverage_date_reads_open_ended_placeholders_as_nil
    %w[99991231 9999-12-31 99991230].each do |raw|
      assert_nil Corvid::Rcm::EligibilityPlan.coverage_date(raw),
                 "expected #{raw.inspect} to normalise to nil"
    end
  end

  def test_coverage_date_parses_a_real_eight_digit_day
    assert_equal Date.new(2026, 8, 15), Corvid::Rcm::EligibilityPlan.coverage_date("20260815")
  end

  # -- base clearinghouse client ---------------------------------------------

  def test_the_base_clearinghouse_client_refuses_check_eligibility
    bare = Corvid::Rcm::ClearinghouseClient.new
    sensitive = inquiry(
      patient_identifier: "pt_token_do_not_log",
      member_identifier: "MBR_TOKEN_DO_NOT_LOG"
    )

    error = assert_raises(NotImplementedError) { bare.check_eligibility(sensitive) }

    refute_includes error.message, sensitive.patient_identifier
    refute_includes error.message, sensitive.member_identifier
  end

  # -- no PHI in eligibility fixture failures --------------------------------

  def test_a_malformed_eligibility_fixture_does_not_leak_the_member_identifier
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "#{MEMBER_MALFORMED_FIXTURE}.271"), "NOT~VALID~271~PAYLOAD")

      client = Corvid::Rcm::FixtureClearinghouseClient.new(
        clock: FIXED_CLOCK,
        eligibility_fixture_dir: dir
      )
      bad = inquiry(member_identifier: MEMBER_MALFORMED_FIXTURE)

      error = assert_raises(StandardError) { client.check_eligibility(bad) }

      refute_includes error.message, MEMBER_MALFORMED_FIXTURE
    end
  end

  # -- subprocess: no database ---------------------------------------------

  def test_the_rcm_module_loads_eligibility_types_without_rails_or_a_database
    lib = File.expand_path("../../../lib", __dir__)
    script = <<~RUBY
      require "corvid/rcm"
      abort("ActiveRecord was loaded") if defined?(ActiveRecord::Base)
      abort("Rails was loaded") if defined?(Rails)
      Corvid::Rcm::EligibilityInquiry
      Corvid::Rcm::EligibilityResponse
      Corvid::Rcm::EligibilityPlan
    RUBY

    assert system(RbConfig.ruby, "-I", lib, "-e", script),
           "corvid/rcm eligibility types must load standalone"
  end
end
