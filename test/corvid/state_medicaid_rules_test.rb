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

  def test_register_normalizes_stored_state_code_encoding_to_utf8
    entry = Corvid::StateMedicaidRules.register("xu".b, expanded: true, groups: minimal_groups)
    assert_equal "XU", entry.state_code
    assert_equal Encoding::UTF_8, entry.state_code.encoding

    stored = Corvid::StateMedicaidRules.state_codes.find { |code| code == "XU" }
    refute_nil stored
    assert_equal Encoding::UTF_8, stored.encoding
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
    register_sample_state("QB")
    register_sample_state("QA")
    assert_equal %w[QA QB], Corvid::StateMedicaidRules.state_codes
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

  def test_register_raises_for_non_ascii_state_code
    %w[ß ﬀ ſc].each do |code|
      assert_raises(ArgumentError) { register_sample_state(code) }
    end
  end

  def test_lookup_unicode_homoglyphs_do_not_match_ascii_registered_states
    Corvid::StateMedicaidRules.register("SS", expanded: true, groups: minimal_groups)
    Corvid::StateMedicaidRules.register("FF", expanded: true, groups: minimal_groups)

    %w[ß ſs ﬀ].each do |code|
      result = Corvid::StateMedicaidRules.lookup(code)
      assert_kind_of Corvid::StateMedicaidRules::NotConfigured, result
      refute result.configured?
    end
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

  def test_register_raises_for_duplicate_group_name_symbol_and_string_keys
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(
        "DG",
        expanded: true,
        groups: {
          other: {
            renewal_months: 12,
            retro_coverage_months: 3,
            work_requirement: false
          },
          "other" => {
            renewal_months: 6,
            retro_coverage_months: 1,
            work_requirement: true
          }
        }
      )
    end
  end

  def test_register_raises_for_duplicate_group_field_symbol_and_string_keys
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(
        "DF",
        expanded: true,
        groups: {
          other: {
            renewal_months: 12,
            "renewal_months" => 6,
            retro_coverage_months: 3,
            work_requirement: false
          }
        }
      )
    end
  end

  def test_register_raises_for_unknown_group_field
    error = assert_raises(ArgumentError) do
      register_with_group(renewal_month: 6)
    end
    assert_match(/renewal_month/, error.message)
  end

  def test_register_raises_for_non_string_symbol_group_attribute_key
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(
        "GK",
        expanded: true,
        groups: { other: { nil => 1 } }
      )
    end
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(
        "GK",
        expanded: true,
        groups: { other: { 1 => 2 } }
      )
    end
  end

  def test_register_raises_for_integer_group_key_zero
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(
        "G0",
        expanded: true,
        groups: {
          0 => {
            renewal_months: 12,
            retro_coverage_months: 3,
            work_requirement: false
          }
        }
      )
    end
  end

  def test_register_raises_for_nil_group_key
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(
        "GN",
        expanded: true,
        groups: {
          nil => {
            renewal_months: 12,
            retro_coverage_months: 3,
            work_requirement: false
          }
        }
      )
    end
  end

  def test_register_raises_for_integer_state_code
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(42, expanded: true, groups: minimal_groups)
    end
  end

  def test_register_raises_for_nil_state_code
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(nil, expanded: true, groups: minimal_groups)
    end
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

  def test_register_raises_when_program_code_is_whitespace_only
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(
        "XC",
        expanded: false,
        work_requirement_programs: [ { code: " ", description_pattern: /x/ } ],
        groups: minimal_groups
      )
    end
  end

  def test_register_raises_for_duplicate_work_requirement_program_codes
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(
        "ZD",
        expanded: false,
        work_requirement_programs: [
          { code: "w", description_pattern: /\bA\b/ },
          { code: "w", description_pattern: /\bB\b/ }
        ],
        groups: minimal_groups
      )
    end
  end

  def test_register_raises_when_description_pattern_matches_empty_string
    [ //, /.*/, /x*/ ].each do |pattern|
      assert_raises(ArgumentError) do
        Corvid::StateMedicaidRules.register(
          "ZP",
          expanded: false,
          work_requirement_programs: [ { code: "empty_match", description_pattern: pattern } ],
          groups: minimal_groups
        )
      end
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

  def test_register_raises_for_duplicate_program_field_symbol_and_string_keys
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(
        "DP",
        expanded: false,
        work_requirement_programs: [
          {
            code: "first",
            "code" => "second",
            description_pattern: /\bDUP\b/
          }
        ],
        groups: minimal_groups
      )
    end
  end

  def test_register_raises_for_unknown_program_field
    error = assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(
        "UP",
        expanded: false,
        work_requirement_programs: [
          { code: "demo", description_pattern: /\bx\b/, typo_code: "x" }
        ],
        groups: minimal_groups
      )
    end
    assert_match(/typo_code/, error.message)
  end

  def test_register_raises_for_non_string_symbol_program_attribute_key
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(
        "PK",
        expanded: false,
        work_requirement_programs: [ { nil => 1 } ],
        groups: minimal_groups
      )
    end
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(
        "PK",
        expanded: false,
        work_requirement_programs: [ { 1 => 2 } ],
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
    assert_nil result.state_code
  end

  def test_lookup_non_string_symbol_returns_not_configured_with_nil_state_code
    [ 42, [ 1 ], { code: "TS" } ].each do |code|
      result = Corvid::StateMedicaidRules.lookup(code)
      assert_kind_of Corvid::StateMedicaidRules::NotConfigured, result
      refute result.configured?
      assert_nil result.state_code
    end
  end

  def test_lookup_non_string_symbol_state_code_not_mutated_by_caller
    code = [ 1 ]
    result = Corvid::StateMedicaidRules.lookup(code)
    code << 2
    assert_nil result.state_code
  end

  def test_lookup_malformed_string_state_code_is_frozen_copy
    code = +"1A"
    result = Corvid::StateMedicaidRules.lookup(code)
    assert_kind_of Corvid::StateMedicaidRules::NotConfigured, result
    assert_equal "1A", result.state_code
    assert result.state_code.frozen?
    code.replace("XX")
    assert_equal "1A", result.state_code
  end

  def test_lookup_symbol_matches_string_registration
    register_sample_state("TS")
    assert Corvid::StateMedicaidRules.lookup(:TS).configured?
    assert_equal "TS", Corvid::StateMedicaidRules.lookup(:ts).state_code
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

  def test_lookup_with_leading_space_returns_not_configured_when_state_registered
    register_sample_state("XA")
    result = Corvid::StateMedicaidRules.lookup(" xa")
    assert_kind_of Corvid::StateMedicaidRules::NotConfigured, result
    refute result.configured?
  end

  def test_lookup_with_trailing_space_returns_not_configured_when_state_registered
    register_sample_state("XA")
    result = Corvid::StateMedicaidRules.lookup("xa ")
    assert_kind_of Corvid::StateMedicaidRules::NotConfigured, result
    refute result.configured?
  end

  def test_lookup_with_trailing_space_on_registered_code_returns_not_configured
    register_sample_state("TS")
    result = Corvid::StateMedicaidRules.lookup("TS ")
    assert_kind_of Corvid::StateMedicaidRules::NotConfigured, result
    refute result.configured?
  end

  def test_lookup_returns_not_configured_for_utf16le_encoded_code_when_xa_registered
    register_sample_state("XA")
    code = "XA".encode("UTF-16LE")
    result = Corvid::StateMedicaidRules.lookup(code)
    assert_kind_of Corvid::StateMedicaidRules::NotConfigured, result
    refute result.configured?
  end

  def test_lookup_returns_not_configured_for_utf32be_encoded_code_when_xa_registered
    register_sample_state("XA")
    code = "XA".encode("UTF-32BE")
    result = Corvid::StateMedicaidRules.lookup(code)
    assert_kind_of Corvid::StateMedicaidRules::NotConfigured, result
    refute result.configured?
  end

  def test_lookup_returns_not_configured_for_invalid_utf8_byte_sequence_when_xa_registered
    register_sample_state("XA")
    code = "\xFF\xFE".dup.force_encoding("UTF-8")
    result = Corvid::StateMedicaidRules.lookup(code)
    assert_kind_of Corvid::StateMedicaidRules::NotConfigured, result
    refute result.configured?
  end

  def test_register_raises_argument_error_for_utf16le_encoded_state_code
    code = "XA".encode("UTF-16LE")
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(code, expanded: true, groups: minimal_groups)
    end
  end

  def test_register_raises_argument_error_for_utf32be_encoded_state_code
    code = "XA".encode("UTF-32BE")
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(code, expanded: true, groups: minimal_groups)
    end
  end

  def test_register_raises_argument_error_for_invalid_utf8_state_code_bytes
    code = "\xFF\xFE".dup.force_encoding("UTF-8")
    assert_raises(ArgumentError) do
      Corvid::StateMedicaidRules.register(code, expanded: true, groups: minimal_groups)
    end
  end

  def test_lookup_does_not_resolve_state_code_via_string_subclass_to_s_alias
    register_sample_state("XA")
    spoof_state_code = Class.new(String) { def to_s = "XA" }
    result = Corvid::StateMedicaidRules.lookup(spoof_state_code.new("QQ"))
    refute result.configured?
    refute_equal "XA", result.state_code if result.state_code
    assert Corvid::StateMedicaidRules.lookup("XA").configured?
  end

  def test_register_does_not_overwrite_state_via_string_subclass_to_s_alias
    register_sample_state("XA")
    xa_entry = Corvid::StateMedicaidRules.lookup("XA")
    spoof_state_code = Class.new(String) { def to_s = "XA" }
    Corvid::StateMedicaidRules.register(
      spoof_state_code.new("QQ"),
      expanded: false,
      groups: minimal_groups
    )
    assert xa_entry.equal?(Corvid::StateMedicaidRules.lookup("XA"))
    qq_entry = Corvid::StateMedicaidRules.lookup("QQ")
    assert qq_entry.configured?
    refute qq_entry.expanded?
  end

  # -- Entry#group -------------------------------------------------------------

  def test_group_returns_nil_for_known_group_not_configured_on_entry
    entry = register_sample_state("GN")
    assert_nil entry.group("waiver_adult")
  end

  def test_group_raises_for_unknown_group_name
    entry = register_sample_state("XG")
    assert_raises(ArgumentError) { entry.group("invalid_group") }
  end

  def test_group_uses_string_own_characters_not_subclass_to_s
    Corvid::StateMedicaidRules.register(
      "XY",
      expanded: false,
      groups: {
        waiver_adult: {
          renewal_months: 12,
          retro_coverage_months: 2,
          work_requirement: true
        },
        other: {
          renewal_months: 6,
          retro_coverage_months: 1,
          work_requirement: false
        }
      }
    )
    entry = Corvid::StateMedicaidRules.lookup("XY")
    spoof_group_name = Class.new(String) { def to_s = "other" }
    group = entry.group(spoof_group_name.new("waiver_adult"))
    refute_nil group
    assert group.work_requirement?
    assert_equal 12, group.renewal_months
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
      "XN",
      expanded: false,
      work_requirement_programs: [ { code: "solo", description_pattern: /\bNOPE\b/ } ],
      groups: minimal_groups
    )
    entry = Corvid::StateMedicaidRules.lookup("XN")
    assert_nil entry.waiver_program_for("unrelated description")
  end

  def test_waiver_program_for_raises_argument_error_when_description_is_undetermined_nil
    entry = register_sample_state("XD")
    assert_raises(ArgumentError) { entry.waiver_program_for(nil) }
  end

  def test_waiver_program_for_raises_argument_error_when_description_is_undetermined_empty
    entry = register_sample_state("BD")
    assert_raises(ArgumentError) { entry.waiver_program_for("") }
  end

  def test_waiver_program_for_raises_argument_error_when_description_is_undetermined_whitespace_only
    entry = register_sample_state("BW")
    assert_raises(ArgumentError) { entry.waiver_program_for("   ") }
  end

  def test_waiver_program_for_raises_argument_error_for_unicode_whitespace_and_invisible_characters
    entry = register_sample_state("XW")
    [
      "\u00A0",
      "\u3000",
      "\u200B",
      "\uFEFF",
      " \u00A0\t"
    ].each do |description|
      assert_raises(ArgumentError) { entry.waiver_program_for(description) }
    end
  end

  def test_waiver_program_for_raises_argument_error_for_non_string_description
    entry = register_sample_state("NS")
    assert_raises(ArgumentError) { entry.waiver_program_for(42) }
  end

  def test_waiver_program_for_raises_argument_error_for_invalid_utf8_bytes_in_description
    Corvid::StateMedicaidRules.register(
      "WU",
      expanded: false,
      work_requirement_programs: [ { code: "caf", description_pattern: /caf/i } ],
      groups: minimal_groups
    )
    entry = Corvid::StateMedicaidRules.lookup("WU")
    description = "caf\xFF waiver".dup.force_encoding("UTF-8")
    assert_raises(ArgumentError) { entry.waiver_program_for(description) }
  end

  def test_waiver_program_for_raises_argument_error_for_utf16le_description
    Corvid::StateMedicaidRules.register(
      "WE",
      expanded: false,
      work_requirement_programs: [ { code: "demo", description_pattern: /demo/i } ],
      groups: minimal_groups
    )
    entry = Corvid::StateMedicaidRules.lookup("WE")
    description = "demo waiver".encode("UTF-16LE")
    assert_raises(ArgumentError) { entry.waiver_program_for(description) }
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
      "XP",
      expanded: false,
      work_requirement_programs: programs,
      groups: minimal_groups
    )
    programs.first[:code] = "changed"
    programs << { code: "extra", description_pattern: /x/ }

    entry = Corvid::StateMedicaidRules.lookup("XP")
    assert_equal "mut", entry.work_requirement_programs.first.code
    assert_equal 1, entry.work_requirement_programs.size
  end

  def test_entry_groups_hash_is_frozen
    entry = register_sample_state("GF")
    assert entry.groups.frozen?
    assert_raises(FrozenError) { entry.groups["other"] = nil }
  end

  def test_mutating_returned_group_does_not_change_subsequent_lookup
    register_sample_state("GR")
    group = Corvid::StateMedicaidRules.lookup("GR").group("expansion_adult")
    assert_raises(FrozenError) { group.renewal_months = 99 }
    again = Corvid::StateMedicaidRules.lookup("GR").group("expansion_adult")
    assert_equal 12, again.renewal_months
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
