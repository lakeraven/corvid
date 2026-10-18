# frozen_string_literal: true

require "minitest/autorun"
require "corvid/state_medicaid_rules"

class Corvid::StateMedicaidRulesTest < Minitest::Test
  def setup
    Corvid::StateMedicaidRules.reset!
  end

  def teardown
    Corvid::StateMedicaidRules.reset!
  end

  # -- Successful registration -------------------------------------------------

  def test_register_and_lookup_returns_configured_entry
    entry = register_sample_state("TS")
    assert entry.configured?
    assert entry.frozen?
    assert_equal "TS", entry.state_code
    assert entry.expanded?

    group = entry.group(:expansion_adult)
    refute_nil group
    assert group.frozen?
    assert_equal 12, group.renewal_months
    assert_equal 3, group.retro_coverage_months
    refute group.work_requirement?

    looked_up = Corvid::StateMedicaidRules.lookup("TS")
    assert looked_up.configured?
    assert_equal entry.state_code, looked_up.state_code
  end

  def test_register_stores_state_code_upcased_from_lowercase_input
    entry = register_sample_state("ts")
    assert_equal "TS", entry.state_code
    assert_equal "TS", Corvid::StateMedicaidRules.lookup("ts").state_code
  end

  def test_register_accepts_string_keyed_group_fields
    Corvid::StateMedicaidRules.register(
      "TK",
      expanded: false,
      groups: {
        other: {
          "renewal_months" => 6,
          "retro_coverage_months" => 2,
          "work_requirement" => true
        }
      }
    )
    group = Corvid::StateMedicaidRules.lookup("TK").group("other")
    assert_equal 6, group.renewal_months
    assert_equal 2, group.retro_coverage_months
    assert group.work_requirement?
  end

  def test_register_with_work_requirement_programs
    Corvid::StateMedicaidRules.register(
      "WP",
      expanded: false,
      work_requirement_programs: [
        { code: "wp_demo", description_pattern: /\bSYNTHETIC\b/i }
      ],
      groups: minimal_groups
    )
    entry = Corvid::StateMedicaidRules.lookup("WP")
    programs = entry.work_requirement_programs
    assert programs.frozen?
    program = programs.first
    assert program.frozen?
    assert_equal "wp_demo", program.code
    assert_equal(/\bSYNTHETIC\b/i, program.description_pattern)
  end

  def test_state_codes_returns_sorted_registered_codes
    register_sample_state("BB")
    register_sample_state("AA")
    assert_equal %w[AA BB], Corvid::StateMedicaidRules.state_codes
  end

  def test_reregister_replaces_existing_entry
    Corvid::StateMedicaidRules.register(
      "RP",
      expanded: true,
      groups: {
        expansion_adult: {
          renewal_months: 12,
          retro_coverage_months: 3,
          work_requirement: false
        }
      }
    )
    Corvid::StateMedicaidRules.register(
      "RP",
      expanded: false,
      groups: {
        other: {
          renewal_months: 6,
          retro_coverage_months: 1,
          work_requirement: true
        }
      }
    )
    entry = Corvid::StateMedicaidRules.lookup("RP")
    refute entry.expanded?
    assert_nil entry.group("expansion_adult")
    assert entry.group("other").work_requirement?
  end

  # -- state_code validation ---------------------------------------------------

  def test_register_raises_for_state_code_too_long
    assert_raises(ArgumentError) { register_sample_state("TEX") }
  end

  def test_register_raises_for_state_code_too_short
    assert_raises(ArgumentError) { register_sample_state("T") }
  end

  def test_register_raises_for_state_code_with_digits
    assert_raises(ArgumentError) { register_sample_state("1A") }
  end

  def test_register_raises_for_empty_state_code
    assert_raises(ArgumentError) { register_sample_state("") }
  end

  # -- expanded validation -----------------------------------------------------

  def test_register_raises_when_expanded_is_nil
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register("EN", expanded: nil, groups: minimal_groups)
    end
  end

  def test_register_raises_when_expanded_is_not_boolean
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register("EN", expanded: "true", groups: minimal_groups)
    end
  end

  def test_register_raises_when_expanded_keyword_omitted
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register("EN", groups: minimal_groups)
    end
  end

  # -- groups validation -------------------------------------------------------

  def test_register_raises_for_empty_groups_hash
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register("EG", expanded: true, groups: {})
    end
  end

  def test_register_raises_for_unknown_group_key
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(
        "UK",
        expanded: true,
        groups: {
          not_a_group: {
            renewal_months: 12,
            retro_coverage_months: 3,
            work_requirement: false
          }
        }
      )
    end
  end

  def test_register_raises_when_group_missing_renewal_months
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(
        "MR",
        expanded: true,
        groups: { other: { retro_coverage_months: 1, work_requirement: false } }
      )
    end
  end

  def test_register_raises_when_group_missing_retro_coverage_months
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(
        "MR",
        expanded: true,
        groups: { other: { renewal_months: 12, work_requirement: false } }
      )
    end
  end

  def test_register_raises_when_group_missing_work_requirement
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(
        "MW",
        expanded: true,
        groups: { other: { renewal_months: 12, retro_coverage_months: 1 } }
      )
    end
  end

  def test_register_raises_when_renewal_months_is_zero
    assert_raises(ArgumentError) { register_with_group(renewal_months: 0) }
  end

  def test_register_raises_when_renewal_months_is_negative
    assert_raises(ArgumentError) { register_with_group(renewal_months: -1) }
  end

  def test_register_raises_when_renewal_months_is_float
    assert_raises(ArgumentError) { register_with_group(renewal_months: 6.0) }
  end

  def test_register_raises_when_renewal_months_is_string
    assert_raises(ArgumentError) { register_with_group(renewal_months: "6") }
  end

  def test_register_raises_when_renewal_months_is_nil
    assert_raises(ArgumentError) { register_with_group(renewal_months: nil) }
  end

  def test_register_raises_when_retro_coverage_months_is_zero
    assert_raises(ArgumentError) { register_with_group(retro_coverage_months: 0) }
  end

  def test_register_raises_when_retro_coverage_months_is_negative
    assert_raises(ArgumentError) { register_with_group(retro_coverage_months: -2) }
  end

  def test_register_raises_when_retro_coverage_months_is_float
    assert_raises(ArgumentError) { register_with_group(retro_coverage_months: 3.0) }
  end

  def test_register_raises_when_retro_coverage_months_is_string
    assert_raises(ArgumentError) { register_with_group(retro_coverage_months: "3") }
  end

  def test_register_raises_when_retro_coverage_months_is_nil
    assert_raises(ArgumentError) { register_with_group(retro_coverage_months: nil) }
  end

  def test_register_raises_when_work_requirement_is_not_boolean
    assert_raises(ArgumentError) { register_with_group(work_requirement: "yes") }
  end

  # -- work_requirement_programs validation ------------------------------------

  def test_register_raises_when_program_code_is_empty
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(
        "PC",
        expanded: false,
        work_requirement_programs: [ { code: "", description_pattern: /x/ } ],
        groups: minimal_groups
      )
    end
  end

  def test_register_raises_when_description_pattern_is_string
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(
        "PS",
        expanded: false,
        work_requirement_programs: [ { code: "demo", description_pattern: "pattern" } ],
        groups: minimal_groups
      )
    end
  end

  def test_register_raises_when_description_pattern_is_nil
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(
        "PN",
        expanded: false,
        work_requirement_programs: [ { code: "demo", description_pattern: nil } ],
        groups: minimal_groups
      )
    end
  end

  # -- lookup: NotConfigured ---------------------------------------------------

  def test_lookup_unregistered_two_letter_code_returns_not_configured
    result = Corvid::StateMedicaidRules.lookup("ZZ")
    assert_kind_of Corvid::StateMedicaidRules::NotConfigured, result
    refute result.configured?
    assert result.frozen?
    assert_equal "ZZ", result.state_code
  end

  def test_lookup_nil_returns_not_configured
    result = Corvid::StateMedicaidRules.lookup(nil)
    assert_kind_of Corvid::StateMedicaidRules::NotConfigured, result
    refute result.configured?
  end

  def test_lookup_empty_string_returns_not_configured
    result = Corvid::StateMedicaidRules.lookup("")
    assert_kind_of Corvid::StateMedicaidRules::NotConfigured, result
    refute result.configured?
  end

  def test_lookup_non_two_letter_name_returns_not_configured
    result = Corvid::StateMedicaidRules.lookup("Texas")
    assert_kind_of Corvid::StateMedicaidRules::NotConfigured, result
    refute result.configured?
  end

  def test_lookup_malformed_two_char_code_with_digit_returns_not_configured
    result = Corvid::StateMedicaidRules.lookup("1A")
    assert_kind_of Corvid::StateMedicaidRules::NotConfigured, result
    refute result.configured?
  end

  def test_lookup_never_returns_default_entry_after_reset
    Corvid::StateMedicaidRules.reset!
    assert_empty Corvid::StateMedicaidRules.state_codes
    result = Corvid::StateMedicaidRules.lookup("TS")
    refute result.configured?
  end

  # -- Entry#group -------------------------------------------------------------

  def test_group_returns_nil_for_known_group_not_configured_on_entry
    entry = register_sample_state("GN")
    assert_nil entry.group("waiver_adult")
  end

  def test_group_raises_for_unknown_group_name
    entry = register_sample_state("GU")
    assert_raises(ArgumentError) { entry.group("invalid_group") }
  end

  # -- Entry#waiver_program_for ------------------------------------------------

  def test_waiver_program_for_returns_first_matching_program
    Corvid::StateMedicaidRules.register(
      "WF",
      expanded: false,
      work_requirement_programs: [
        { code: "first", description_pattern: /\bALPHA\b/ },
        { code: "second", description_pattern: /\bALPHA\b/ }
      ],
      groups: minimal_groups
    )
    entry = Corvid::StateMedicaidRules.lookup("WF")
    match = entry.waiver_program_for("coverage under ALPHA plan")
    assert_equal "first", match.code
  end

  def test_waiver_program_for_returns_nil_when_no_match
    Corvid::StateMedicaidRules.register(
      "NM",
      expanded: false,
      work_requirement_programs: [ { code: "solo", description_pattern: /\bNOPE\b/ } ],
      groups: minimal_groups
    )
    entry = Corvid::StateMedicaidRules.lookup("NM")
    assert_nil entry.waiver_program_for("unrelated description")
  end

  def test_waiver_program_for_returns_nil_for_nil_description
    entry = register_sample_state("ND")
    assert_nil entry.waiver_program_for(nil)
  end

  def test_waiver_program_for_returns_nil_for_blank_description
    entry = register_sample_state("BD")
    assert_nil entry.waiver_program_for("   ")
  end

  # -- Immutability ------------------------------------------------------------

  def test_mutating_groups_hash_after_register_does_not_change_entry
    groups = {
      other: {
        renewal_months: 12,
        retro_coverage_months: 3,
        work_requirement: false
      }
    }
    Corvid::StateMedicaidRules.register("IM", expanded: true, groups: groups)
    groups[:other][:renewal_months] = 99
    groups[:new_key] = { renewal_months: 1, retro_coverage_months: 1, work_requirement: false }

    entry = Corvid::StateMedicaidRules.lookup("IM")
    assert_equal 12, entry.group("other").renewal_months
  end

  def test_mutating_work_requirement_programs_after_register_does_not_change_entry
    programs = [ { code: "mut", description_pattern: /\bMUT\b/ } ]
    Corvid::StateMedicaidRules.register(
      "MP",
      expanded: false,
      work_requirement_programs: programs,
      groups: minimal_groups
    )
    programs.first[:code] = "changed"
    programs << { code: "extra", description_pattern: /x/ }

    entry = Corvid::StateMedicaidRules.lookup("MP")
    assert_equal "mut", entry.work_requirement_programs.first.code
    assert_equal 1, entry.work_requirement_programs.size
  end

  def test_groups_constant_lists_eligibility_groups
    assert_equal %w[expansion_adult waiver_adult other], Corvid::StateMedicaidRules::GROUPS
  end

  private

  def minimal_groups
    {
      other: {
        renewal_months: 12,
        retro_coverage_months: 1,
        work_requirement: false
      }
    }
  end

  def register_sample_state(code)
    Corvid::StateMedicaidRules.register(
      code,
      expanded: true,
      groups: {
        expansion_adult: {
          renewal_months: 12,
          retro_coverage_months: 3,
          work_requirement: false
        }
      }
    )
  end

  def register_with_group(**overrides)
    base = {
      renewal_months: 12,
      retro_coverage_months: 3,
      work_requirement: false
    }
    Corvid::StateMedicaidRules.register(
      "GV",
      expanded: true,
      groups: { other: base.merge(overrides) }
    )
  end
end
