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

  def test_benefit_level_dtp_346_after_eb_does_not_set_coverage_start
    plan = plan_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [
        "EB*1*IND*30",
        "DTP*346*D8*20260101"
      ]
    ))

    assert_nil plan.coverage_start
  end

  def test_ref_6p_after_eb_does_not_set_group_number
    plan = plan_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [
        "EB*1*IND*30",
        "REF*6P*GRP-AFTER-EB"
      ]
    ))

    assert_nil plan.group_number
  end

  # -- #736 review-2: most restrictive plan bounds (reader) ------------------

  def test_coverage_end_is_earliest_end_ignoring_year_9999_placeholder
    plan = plan_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [
        "DTP*347*D8*99991231",
        "DTP*357*D8*20260731",
        "EB*1*IND*30"
      ]
    ))

    assert_equal Date.new(2026, 7, 31), plan.coverage_end
  end

  def test_rd8_291_range_end_placeholder_does_not_block_a_later_explicit_end
    plan = plan_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [
        "DTP*291*RD8*20260101-99991231",
        "DTP*357*D8*20260731",
        "EB*1*IND*30"
      ]
    ))

    assert_equal Date.new(2026, 7, 31), plan.coverage_end
  end

  def test_coverage_start_is_latest_start_across_plan_date_dtps
    plan = plan_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [
        "DTP*346*D8*20200101",
        "DTP*356*D8*20261001",
        "EB*1*IND*30"
      ]
    ))

    assert_equal Date.new(2026, 10, 1), plan.coverage_start
  end

  def test_dependent_loop_merges_subscriber_and_dependent_plan_dates_before_first_eb
    plan = plan_for(build_271(
      member_token: MEMBER,
      subscriber_hl_has_child: true,
      body_after_subscriber: [
        "DTP*346*D8*20250101",
        "DTP*347*D8*20251231",
        "HL*4*3*23*0",
        "NM1*03*1******MI*MBR-SYNTH-DEP-DATES",
        "EB*1*IND*30"
      ]
    ))

    assert_equal Date.new(2025, 1, 1), plan.coverage_start
    assert_equal Date.new(2025, 12, 31), plan.coverage_end
  end

  # -- #736 review-2: plan-date qualifiers -----------------------------------

  def test_dtp_307_rd8_sets_plan_window_bounds
    plan = plan_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [
        "DTP*307*RD8*20250101-20260731",
        "EB*1*IND*30"
      ]
    ))

    assert_equal Date.new(2025, 1, 1), plan.coverage_start
    assert_equal Date.new(2026, 7, 31), plan.coverage_end
  end

  def test_dtp_307_d8_sets_both_bounds_to_eligibility_day
    plan = plan_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [
        "DTP*307*D8*20260731",
        "EB*1*IND*30"
      ]
    ))

    assert_equal Date.new(2026, 7, 31), plan.coverage_start
    assert_equal Date.new(2026, 7, 31), plan.coverage_end
  end

  def test_dtp_540_d8_sets_coverage_end
    plan = plan_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [
        "DTP*540*D8*20260731",
        "EB*1*IND*30"
      ]
    ))

    assert_nil plan.coverage_start
    assert_equal Date.new(2026, 7, 31), plan.coverage_end
  end

  def test_dtp_347_rd8_range_sets_start_and_end
    plan = plan_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [
        "DTP*347*RD8*20250101-20250630",
        "EB*1*IND*30"
      ]
    ))

    assert_equal Date.new(2025, 1, 1), plan.coverage_start
    assert_equal Date.new(2025, 6, 30), plan.coverage_end
  end

  # -- #736 review-2: unreadable plan dates raise MalformedError ------------

  def test_impossible_calendar_day_on_plan_dtp_raises_malformed_error
    content = build_271(
      member_token: MEMBER,
      body_after_subscriber: [ "DTP*357*D8*20260231", "EB*1*IND*30" ]
    )

    error = assert_raises(Reader::MalformedError) { parse(content) }

    assert_equal Reader::MALFORMED_MESSAGE, error.message
  end

  def test_short_plan_date_raises_malformed_error
    content = build_271(
      member_token: MEMBER,
      body_after_subscriber: [ "DTP*357*D8*2026073", "EB*1*IND*30" ]
    )

    assert_raises(Reader::MalformedError) { parse(content) }
  end

  def test_malformed_rd8_half_raises_malformed_error
    content = build_271(
      member_token: MEMBER,
      body_after_subscriber: [ "DTP*346*RD8*20260101-20260231", "EB*1*IND*30" ]
    )

    assert_raises(Reader::MalformedError) { parse(content) }
  end

  def test_year_9999_placeholder_on_plan_dtp_is_not_unreadable
    plan = plan_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [ "DTP*357*D8*99991231", "EB*1*IND*30" ]
    ))

    assert_nil plan.coverage_end
  end

  # -- #736 review-2: encoding -----------------------------------------------

  def test_valid_utf8_in_ignored_subscriber_name_parses_active_coverage
    content = build_271(
      member_token: MEMBER,
      body_after_subscriber: [ "EB*1*IND*30" ]
    )
    content.sub!(
      "NM1*IL*1******MI*#{MEMBER}",
      "NM1*IL*1*TEST\u00C9******MI*#{MEMBER}"
    )

    result = parse(content)

    assert_equal 1, result.plans.length
    assert_equal "1", result.plans.first.benefits.first.code
  end

  # -- #736 review-2: mutation pins (reader) --------------------------------

  def test_truncated_271_missing_se_raises_malformed_error
    content = build_271(member_token: MEMBER, body_after_subscriber: [ "EB*1*IND*30" ], include_trailer: false)

    assert_raises(Reader::MalformedError) { parse(content) }
  end

  def test_wrong_se02_control_number_raises_malformed_error
    content = build_271(member_token: MEMBER, body_after_subscriber: [ "EB*1*IND*30" ], st_control: "9001")
    content.sub!(/SE\*\d+\*9001/, "SE*12*WRONG")

    assert_raises(Reader::MalformedError) { parse(content) }
  end

  def test_two_st_transactions_in_one_interchange_raises_malformed_error
    content = build_271_with_second_transaction(
      member_token: MEMBER,
      first_body: [ "EB*1*IND*30" ],
      second_body: [ "EB*1*IND*30" ]
    )

    assert_raises(Reader::MalformedError) { parse(content) }
  end

  def test_aaa_n_without_reject_code_surfaces_error_and_blocks_clean_parse
    result = parse(build_271(
      member_token: MEMBER,
      body_after_subscriber: [ "AAA*N", "EB*1*IND*30" ]
    ))

    refute_empty result.errors
    assert result.errors.any? { |entry| entry.code == "N" }
  end

  def test_aaa_y_with_reject_code_42_surfaces_error_code_42
    result = parse(build_271(
      member_token: MEMBER,
      body_after_subscriber: [ "AAA*Y**42*C", "EB*1*IND*30" ]
    ))

    error = result.errors.find { |entry| entry.code == "42" }
    refute_nil error
  end

  def test_eb12_n_maps_in_network_false
    benefit = benefit_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [ "EB*1*IND*30*********N" ]
    ))

    assert_equal false, benefit.in_network
  end

  def test_eb12_w_and_u_map_in_network_to_nil
    w = benefit_for(build_271(member_token: MEMBER, body_after_subscriber: [ "EB*1*IND*30*********W" ]))
    u = benefit_for(build_271(member_token: MEMBER, body_after_subscriber: [ "EB*1*IND*30*********U" ]))

    assert_nil w.in_network
    assert_nil u.in_network
  end

  def test_copay_eb_does_not_replace_plan_name_from_coverage_eb
    plan = plan_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [
        "EB*1*IND*30*MC*COVERAGE PLAN",
        "EB*B*IND*30***27*25*****Y"
      ]
    ))

    assert_equal "COVERAGE PLAN", plan.plan_name
  end

  def test_subscriber_loop_pr_nm1_does_not_replace_information_source_payer
    plan = plan_for(build_271(
      member_token: MEMBER,
      body_after_subscriber: [
        "NM1*PR*2*OTHER PAYER*****PI*OTHERPAYER",
        "EB*1*IND*30"
      ]
    ))

    assert_equal "EXPAYER01", plan.payer_identifier
  end

  def test_unmapped_aaa_code_99_uses_unmapped_reject_description
    result = parse(build_271(member_token: MEMBER, body_after_subscriber: [ "AAA*N**99*C" ]))

    error = result.errors.find { |entry| entry.code == "99" }
    refute_nil error
    assert_equal Reader::UNMAPPED_REJECT_DESCRIPTION, error.description
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
