# frozen_string_literal: true

require "minitest/autorun"
require "bigdecimal"
require "corvid/rcm"
require_relative "edi_271_test_helper"

class Corvid::Rcm::Edi271ReaderTest < Minitest::Test
  include Corvid::Rcm::Edi271TestHelper

  Reader = Corvid::Rcm::Edi271Reader
  MEMBER = "MBR-READER-SYNTH"

  def parse(string)
    Reader.parse(string)
  end

  def plan_for(string)
    result = parse(string)
    assert_equal 1, result.plans.length, result.errors.inspect
    result.plans.first
  end

  def benefit_for(string)
    plan_for(string).benefits.first
  end

  # -- G: malformed interchange ------------------------------------------------

  def test_wrong_se01_segment_count_raises_malformed_error
    content = build_271(member_token: MEMBER, body_after_subscriber: [ "EB*1*IND*30" ])
    content.sub!(/SE\*(\d+)\*/, "SE*999*")

    error = assert_raises(Reader::MalformedError) { parse(content) }

    assert_equal Reader::MALFORMED_MESSAGE, error.message
  end

  def test_non_default_isa_delimiters_parse_like_the_default_version
    body = [
      "REF*6P*GRP-A",
      "EB*1*IND*30*MC*SYNTHETIC PPO PLAN",
      "EB*B*IND*30***27*25*****Y"
    ]
    default_string = build_271(member_token: MEMBER, body_after_subscriber: body, st_control: "9100")
    pipe_string = build_271(
      member_token: MEMBER,
      body_after_subscriber: body,
      st_control: "9100",
      profile: :pipes
    )

    default_result = parse(default_string)
    pipe_result = parse(pipe_string)

    assert_equal default_result.plans, pipe_result.plans
    assert_equal default_result.errors, pipe_result.errors
    assert_equal default_result.raw_reference, pipe_result.raw_reference
  end

  def test_invalid_utf8_byte_raises_malformed_error_without_member_token_in_message
    content = build_271(member_token: MEMBER, body_after_subscriber: [ "EB*1*IND*30" ])
    invalid = (content.b + "\xFF".b).force_encoding(Encoding::UTF_8)

    error = assert_raises(Reader::MalformedError) { parse(invalid) }

    refute_includes error.message, MEMBER
    assert_equal Reader::MALFORMED_MESSAGE, error.message
  end

  # -- F: EB field positions (005010X279A1) ----------------------------------

  def test_eb_copay_line_maps_amount_and_in_network
    benefit = benefit_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [ "EB*B*IND*30***27*25*****Y" ]
    ))

    assert_equal "B", benefit.code
    assert_equal "IND", benefit.coverage_level
    assert_kind_of BigDecimal, benefit.amount
    assert_equal BigDecimal("25"), benefit.amount
    assert benefit.in_network
  end

  def test_eb_coinsurance_line_maps_percent_and_out_of_network
    benefit = benefit_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [ "EB*A*IND*30***27**.2****N" ]
    ))

    assert_kind_of BigDecimal, benefit.percent
    assert_equal BigDecimal("0.2"), benefit.percent
    refute benefit.in_network
  end

  def test_coverage_eb_with_eb05_sets_plan_name
    plan = plan_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [ "EB*1*IND*30*MC*SYNTHETIC PPO PLAN" ]
    ))

    assert_equal "SYNTHETIC PPO PLAN", plan.plan_name
  end

  def test_coverage_eb_with_only_eb04_insurance_type_does_not_set_plan_name
    plan = plan_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [ "EB*1*IND*30*MC" ]
    ))

    assert_nil plan.plan_name
  end

  def test_ref_6p_sets_group_number
    plan = plan_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [ "REF*6P*GRP-A", "EB*1*IND*30" ]
    ))

    assert_equal "GRP-A", plan.group_number
  end

  def test_ref_1l_sets_group_number_when_6p_is_absent
    plan = plan_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [ "REF*1L*GRP-B", "EB*1*IND*30" ]
    ))

    assert_equal "GRP-B", plan.group_number
  end

  def test_ref_6p_wins_over_ref_1l_when_both_are_present
    plan = plan_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [ "REF*1L*GRP-B", "REF*6P*GRP-A", "EB*1*IND*30" ]
    ))

    assert_equal "GRP-A", plan.group_number
  end

  def test_raw_reference_uses_st_control_and_omits_member_identifier
    result = parse(build_271(
      member_token: MEMBER,
      body_after_subscriber: [ "EB*1*IND*30" ],
      st_control: "9201"
    ))

    assert_equal "st:9201", result.raw_reference
    refute_includes result.raw_reference, MEMBER
  end

  # -- D: plan coverage dates from subscriber DTP before first EB --------------

  def test_subscriber_dtp_346_and_347_before_eb_set_coverage_bounds
    plan = plan_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [
        "DTP*346*D8*20250101",
        "DTP*347*D8*20250630",
        "EB*1*IND*30"
      ]
    ))

    assert_equal Date.new(2025, 1, 1), plan.coverage_start
    assert_equal Date.new(2025, 6, 30), plan.coverage_end
  end

  def test_dtp_346_rd8_range_sets_start_and_end_before_first_eb
    plan = plan_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [
        "DTP*346*RD8*20250201-20250815",
        "EB*1*IND*30"
      ]
    ))

    assert_equal Date.new(2025, 2, 1), plan.coverage_start
    assert_equal Date.new(2025, 8, 15), plan.coverage_end
  end

  def test_dtp_472_service_date_range_does_not_set_plan_coverage_dates
    plan = plan_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [
        "DTP*472*RD8*20250301-20250331",
        "DTP*346*D8*20250101",
        "DTP*347*D8*20250630",
        "EB*1*IND*30"
      ]
    ))

    assert_equal Date.new(2025, 1, 1), plan.coverage_start
    assert_equal Date.new(2025, 6, 30), plan.coverage_end
  end

  def test_benefit_level_dtp_348_and_349_after_eb_do_not_change_plan_coverage_dates
    plan = plan_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [
        "EB*1*IND*30",
        "DTP*348*D8*20240101",
        "DTP*349*D8*20241231"
      ]
    ))

    assert_nil plan.coverage_start
    assert_nil plan.coverage_end
  end

  # -- E: dependent loop structure (reader) ----------------------------------

  def test_multiple_subscriber_hl_loops_do_not_yield_a_clean_single_active_plan
    content = build_271_transaction(
      member_token: "MBR-MULTI-SUB-A",
      segments_after_subscriber: [
        "EB*1*IND*30",
        "HL*4*2*22*0",
        "NM1*IL*1******MI*MBR-MULTI-SUB-B",
        "EB*1*IND*30"
      ],
      st_control: "9301"
    )

    refute_clean_single_active_plan(content)
  end

  def test_multiple_dependent_hl_loops_do_not_yield_a_clean_single_active_plan
    content = build_271(
      member_token: "MBR-MULTI-DEP-PARENT",
      subscriber_hl_has_child: true,
      body_after_subscriber: [
        "HL*4*3*23*1",
        "NM1*03*1******MI*MBR-MULTI-DEP-ONE",
        "EB*1*IND*30",
        "HL*5*4*23*0",
        "NM1*03*1******MI*MBR-MULTI-DEP-TWO",
        "EB*1*IND*30"
      ],
      st_control: "9302"
    )

    refute_clean_single_active_plan(content)
  end

  private

  def refute_clean_single_active_plan(content)
    result = parse(content)
    refute clean_single_active?(result)
  rescue Reader::MalformedError
    # acceptable
  end

  def clean_single_active?(result)
    return false unless result.errors.empty?
    return false unless result.plans.length == 1

    benefits = result.plans.first.benefits
    active = benefits.select { |benefit| benefit.code == "1" }
    inactive = benefits.select { |benefit| benefit.code == "6" }
    active.any? && inactive.empty?
  end
end
