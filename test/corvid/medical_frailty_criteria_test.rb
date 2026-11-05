# frozen_string_literal: true

require "minitest/autorun"
require "corvid"

class Corvid::MedicalFrailtyCriteriaTest < Minitest::Test
  SECRET_INVALID = "CRITERIA_INVALID_ECHO_XYZ"
  RX_SYSTEM = "http://example.test/rxnorm"

  def setup
    Corvid::MedicalFrailtyCriteria.reset!
  end

  def teardown
    Corvid::MedicalFrailtyCriteria.reset!
  end

  def test_engine_ships_no_states_until_registered
    assert_empty Corvid::MedicalFrailtyCriteria.state_codes
  end

  def test_register_and_lookup_returns_configured_frozen_entry
    entry = register_sample("XF")
    assert entry.configured?
    assert entry.frozen?
    assert_equal "XF", entry.state_code

    categories = entry.categories
    assert categories.frozen?
    assert_equal %w[synthetic_z9981], categories.keys.sort

    looked_up = Corvid::MedicalFrailtyCriteria.lookup("XF")
    assert looked_up.configured?
    assert_equal entry.state_code, looked_up.state_code
  end

  def test_register_stores_state_code_upcased_from_lowercase_input
    entry = register_sample("xf")
    assert_equal "XF", entry.state_code
    assert_equal "XF", Corvid::MedicalFrailtyCriteria.lookup("xf").state_code
  end

  def test_register_normalizes_symbol_category_keys_to_strings
    Corvid::MedicalFrailtyCriteria.register(
      "XK",
      categories: {
        synthetic_only: {
          icd10_prefixes: [ "Z9981" ],
          medication_codes: [],
          procedure_codes: []
        }
      }
    )
    entry = Corvid::MedicalFrailtyCriteria.lookup("XK")
    assert entry.categories.key?("synthetic_only")
  end

  def test_register_accepts_category_with_only_medication_codes
    Corvid::MedicalFrailtyCriteria.register(
      "XM",
      categories: {
        med_only: {
          icd10_prefixes: [],
          medication_codes: [ { system: RX_SYSTEM, code: "RX_TEST_001" } ],
          procedure_codes: []
        }
      }
    )
    entry = Corvid::MedicalFrailtyCriteria.lookup("XM")
    refute_empty entry.categories["med_only"].medication_codes
  end

  def test_register_accepts_category_with_only_procedure_codes
    Corvid::MedicalFrailtyCriteria.register(
      "XP",
      categories: {
        proc_only: {
          icd10_prefixes: [],
          medication_codes: [],
          procedure_codes: [ "HCPCS_TEST_A" ]
        }
      }
    )
    entry = Corvid::MedicalFrailtyCriteria.lookup("XP")
    refute_empty entry.categories["proc_only"].procedure_codes
  end

  def test_state_codes_returns_sorted_registered_codes
    register_sample("QB")
    register_sample("QA")
    assert_equal %w[QA QB], Corvid::MedicalFrailtyCriteria.state_codes
  end

  def test_reregister_replaces_existing_entry
    Corvid::MedicalFrailtyCriteria.register(
      "RP",
      categories: {
        first_cat: {
          icd10_prefixes: [ "A001" ],
          medication_codes: [],
          procedure_codes: []
        }
      }
    )
    Corvid::MedicalFrailtyCriteria.register(
      "RP",
      categories: {
        second_cat: {
          icd10_prefixes: [],
          medication_codes: [ { system: RX_SYSTEM, code: "RX_TEST_002" } ],
          procedure_codes: []
        }
      }
    )
    entry = Corvid::MedicalFrailtyCriteria.lookup("RP")
    assert entry.categories.key?("second_cat")
    refute entry.categories.key?("first_cat")
  end

  def test_lookup_unregistered_two_letter_code_returns_not_configured
    result = Corvid::MedicalFrailtyCriteria.lookup("ZZ")
    assert_kind_of Corvid::MedicalFrailtyCriteria::NotConfigured, result
    refute result.configured?
    assert result.frozen?
    assert_equal "ZZ", result.state_code
  end

  def test_lookup_symbol_matches_string_registration
    register_sample("TS")
    assert Corvid::MedicalFrailtyCriteria.lookup(:TS).configured?
    assert_equal "TS", Corvid::MedicalFrailtyCriteria.lookup(:ts).state_code
  end

  def test_lookup_malformed_string_returns_not_configured
    result = Corvid::MedicalFrailtyCriteria.lookup("1A")
    assert_kind_of Corvid::MedicalFrailtyCriteria::NotConfigured, result
    refute result.configured?
  end

  def test_register_raises_for_invalid_state_code_without_echoing_input
    error = assert_raises(ArgumentError) do
      Corvid::MedicalFrailtyCriteria.register(
        SECRET_INVALID,
        categories: minimal_categories
      )
    end
    refute_match(/#{SECRET_INVALID}/, error.message)
  end

  def test_register_raises_for_empty_categories_hash
    error = assert_raises(ArgumentError) do
      Corvid::MedicalFrailtyCriteria.register("EG", categories: {})
    end
    refute_match(/EG/, error.message)
  end

  def test_register_raises_when_category_has_no_codes_anywhere
    error = assert_raises(ArgumentError) do
      Corvid::MedicalFrailtyCriteria.register(
        "EC",
        categories: {
          empty_cat: {
            icd10_prefixes: [],
            medication_codes: [],
            procedure_codes: []
          }
        }
      )
    end
    refute_match(/empty_cat/, error.message)
  end

  def test_register_raises_for_blank_category_key_without_echoing_input
    error = assert_raises(ArgumentError) do
      Corvid::MedicalFrailtyCriteria.register(
        "BK",
        categories: {
          "   " => {
            icd10_prefixes: [ "Z9981" ],
            medication_codes: [],
            procedure_codes: []
          }
        }
      )
    end
    refute_match(/   /, error.message)
  end

  def test_register_raises_for_duplicate_category_symbol_and_string_keys
    assert_raises(ArgumentError) do
      Corvid::MedicalFrailtyCriteria.register(
        "DG",
        categories: {
          dup_cat: {
            icd10_prefixes: [ "Z9981" ],
            medication_codes: [],
            procedure_codes: []
          },
          "dup_cat" => {
            icd10_prefixes: [ "A001" ],
            medication_codes: [],
            procedure_codes: []
          }
        }
      )
    end
  end

  def test_register_raises_for_non_string_symbol_category_key
    assert_raises(ArgumentError) do
      Corvid::MedicalFrailtyCriteria.register(
        "GK",
        categories: {
          1 => {
            icd10_prefixes: [ "Z9981" ],
            medication_codes: [],
            procedure_codes: []
          }
        }
      )
    end
  end

  def test_register_raises_for_blank_icd10_prefix_without_echoing_value
    error = assert_raises(ArgumentError) do
      Corvid::MedicalFrailtyCriteria.register(
        "BI",
        categories: {
          bad_prefix: {
            icd10_prefixes: [ SECRET_INVALID ],
            medication_codes: [],
            procedure_codes: []
          }
        }
      )
    end
    refute_match(/#{SECRET_INVALID}/, error.message)
  end

  def test_register_raises_for_blank_procedure_code_without_echoing_value
    error = assert_raises(ArgumentError) do
      Corvid::MedicalFrailtyCriteria.register(
        "BP",
        categories: {
          bad_proc: {
            icd10_prefixes: [],
            medication_codes: [],
            procedure_codes: [ SECRET_INVALID ]
          }
        }
      )
    end
    refute_match(/#{SECRET_INVALID}/, error.message)
  end

  def test_register_raises_when_medication_entry_missing_system
    error = assert_raises(ArgumentError) do
      Corvid::MedicalFrailtyCriteria.register(
        "MS",
        categories: {
          bad_med: {
            icd10_prefixes: [],
            medication_codes: [ { code: "RX_TEST_003" } ],
            procedure_codes: []
          }
        }
      )
    end
    refute_match(/RX_TEST_003/, error.message)
  end

  def test_register_raises_when_medication_entry_missing_code
    error = assert_raises(ArgumentError) do
      Corvid::MedicalFrailtyCriteria.register(
        "MC",
        categories: {
          bad_med: {
            icd10_prefixes: [],
            medication_codes: [ { system: RX_SYSTEM } ],
            procedure_codes: []
          }
        }
      )
    end
    refute_match(/#{RX_SYSTEM}/, error.message)
  end

  def test_register_raises_for_unknown_category_field
    error = assert_raises(ArgumentError) do
      Corvid::MedicalFrailtyCriteria.register(
        "UK",
        categories: {
          extra_field: {
            icd10_prefixes: [ "Z9981" ],
            medication_codes: [],
            procedure_codes: [],
            typo_field: true
          }
        }
      )
    end
    refute_match(/typo_field/, error.message)
  end

  def test_mutating_categories_hash_after_register_does_not_change_entry
    categories = minimal_categories
    Corvid::MedicalFrailtyCriteria.register("IM", categories: categories)
    categories[:synthetic_z9981][:icd10_prefixes] << "EXTRA"
    categories[:new_cat] = {
      icd10_prefixes: [ "B001" ],
      medication_codes: [],
      procedure_codes: []
    }

    entry = Corvid::MedicalFrailtyCriteria.lookup("IM")
    assert_equal [ "Z9981" ], entry.categories["synthetic_z9981"].icd10_prefixes
    refute entry.categories.key?("new_cat")
  end

  def test_mutating_medication_codes_after_register_does_not_change_entry
    meds = [ { system: RX_SYSTEM, code: "RX_TEST_004" } ]
    Corvid::MedicalFrailtyCriteria.register(
      "MM",
      categories: {
        med_cat: {
          icd10_prefixes: [],
          medication_codes: meds,
          procedure_codes: []
        }
      }
    )
    meds.first[:code] = "CHANGED"

    entry = Corvid::MedicalFrailtyCriteria.lookup("MM")
    assert_equal "RX_TEST_004", entry.categories["med_cat"].medication_codes.first[:code]
  end

  # ---- Issue #794 gate round 3 spec amendment (rule A: registry cleaning) ----

  def test_register_raises_when_icd10_prefix_blank_after_surrounding_whitespace_stripped
    error = assert_raises(ArgumentError) do
      Corvid::MedicalFrailtyCriteria.register(
        "AW",
        categories: {
          bad_prefix: {
            icd10_prefixes: [ "\u00A0" ],
            medication_codes: [],
            procedure_codes: []
          }
        }
      )
    end
    refute_match(/\u00A0/, error.message)
  end

  def test_register_raises_when_procedure_code_blank_after_surrounding_whitespace_stripped
    error = assert_raises(ArgumentError) do
      Corvid::MedicalFrailtyCriteria.register(
        "PW",
        categories: {
          bad_proc: {
            icd10_prefixes: [],
            medication_codes: [],
            procedure_codes: [ "\u200B" ]
          }
        }
      )
    end
    refute_match(/\u200B/, error.message)
  end

  def test_register_raises_when_medication_code_blank_after_surrounding_whitespace_stripped
    error = assert_raises(ArgumentError) do
      Corvid::MedicalFrailtyCriteria.register(
        "CW",
        categories: {
          bad_med: {
            icd10_prefixes: [],
            medication_codes: [ { system: RX_SYSTEM, code: "\u3000" } ],
            procedure_codes: []
          }
        }
      )
    end
    refute_match(/\u3000/, error.message)
  end

  def test_register_raises_when_medication_system_blank_after_surrounding_whitespace_stripped
    error = assert_raises(ArgumentError) do
      Corvid::MedicalFrailtyCriteria.register(
        "SW",
        categories: {
          bad_med: {
            icd10_prefixes: [],
            medication_codes: [ { system: "\u00A0", code: "RX_TEST_005" } ],
            procedure_codes: []
          }
        }
      )
    end
    refute_match(/\u00A0/, error.message)
  end

  def test_register_stores_medication_system_without_surrounding_unicode_whitespace
    plain_system = "http://example.test/rx"
    Corvid::MedicalFrailtyCriteria.register(
      "WS",
      categories: {
        pad_med: {
          icd10_prefixes: [],
          medication_codes: [
            { system: "#{plain_system}\u00A0", code: "RX_PAD_001" },
            { system: "#{plain_system}\u200B", code: "RX_PAD_002" }
          ],
          procedure_codes: []
        }
      }
    )

    entry = Corvid::MedicalFrailtyCriteria.lookup("WS")
    stored = entry.categories["pad_med"].medication_codes
    assert_equal plain_system, stored[0][:system]
    assert_equal plain_system, stored[1][:system]
  end

  def test_register_stores_icd10_prefix_without_surrounding_unicode_whitespace
    Corvid::MedicalFrailtyCriteria.register(
      "WI",
      categories: {
        pad_icd: {
          icd10_prefixes: [ "\u00A0Z9981\u200B" ],
          medication_codes: [],
          procedure_codes: []
        }
      }
    )

    entry = Corvid::MedicalFrailtyCriteria.lookup("WI")
    assert_equal "Z9981", entry.categories["pad_icd"].icd10_prefixes.first
  end

  def test_register_stores_procedure_code_without_surrounding_unicode_whitespace
    Corvid::MedicalFrailtyCriteria.register(
      "WP",
      categories: {
        pad_proc: {
          icd10_prefixes: [],
          medication_codes: [],
          procedure_codes: [ "\u3000HCPCS_PAD_A\u00A0" ]
        }
      }
    )

    entry = Corvid::MedicalFrailtyCriteria.lookup("WP")
    assert_equal "HCPCS_PAD_A", entry.categories["pad_proc"].procedure_codes.first
  end

  def test_register_raises_when_medication_system_contains_nul_after_surrounding_strip
    assert_raises(ArgumentError) do
      Corvid::MedicalFrailtyCriteria.register(
        "NU",
        categories: {
          bad_med: {
            icd10_prefixes: [],
            medication_codes: [ { system: "http://example.test/rx\u0000", code: "RX_TEST_006" } ],
            procedure_codes: []
          }
        }
      )
    end
  end

  def test_register_raises_when_medication_code_contains_interior_whitespace
    assert_raises(ArgumentError) do
      Corvid::MedicalFrailtyCriteria.register(
        "MW",
        categories: {
          bad_med: {
            icd10_prefixes: [],
            medication_codes: [ { system: RX_SYSTEM, code: "RX\u0009TEST" } ],
            procedure_codes: []
          }
        }
      )
    end
  end

  def test_register_raises_when_icd10_prefix_contains_interior_control_character
    assert_raises(ArgumentError) do
      Corvid::MedicalFrailtyCriteria.register(
        "IC",
        categories: {
          bad_prefix: {
            icd10_prefixes: [ "Z99\u000081" ],
            medication_codes: [],
            procedure_codes: []
          }
        }
      )
    end
  end

  def test_register_raises_for_medication_system_that_is_not_uri_shaped
    error = assert_raises(ArgumentError) do
      Corvid::MedicalFrailtyCriteria.register(
        "UR",
        categories: {
          bad_med: {
            icd10_prefixes: [],
            medication_codes: [ { system: "not a uri", code: "RX_TEST_007" } ],
            procedure_codes: []
          }
        }
      )
    end
    refute_match(/not a uri/, error.message)
  end

  def test_lookup_category_code_lists_and_medication_hashes_are_frozen
    entry = register_sample("FZ")
    category = Corvid::MedicalFrailtyCriteria.lookup("FZ").categories["synthetic_z9981"]

    assert category.icd10_prefixes.frozen?
    assert category.procedure_codes.frozen?
    assert category.medication_codes.frozen?
    assert category.medication_codes.first.frozen?
  end

  def test_mutating_lookup_icd10_prefixes_raises_frozen_error
    register_sample("ML")
    prefixes = Corvid::MedicalFrailtyCriteria.lookup("ML").categories["synthetic_z9981"].icd10_prefixes
    assert_raises(FrozenError) { prefixes << "MUTATED" }
  end

  def test_mutating_lookup_procedure_codes_raises_frozen_error
    register_sample("MP")
    procedures = Corvid::MedicalFrailtyCriteria.lookup("MP").categories["synthetic_z9981"].procedure_codes
    assert_raises(FrozenError) { procedures[0] = "MUTATED" }
  end

  def test_mutating_lookup_medication_codes_raises_frozen_error
    register_sample("MQ")
    medications = Corvid::MedicalFrailtyCriteria.lookup("MQ").categories["synthetic_z9981"].medication_codes
    assert_raises(FrozenError) { medications << { system: RX_SYSTEM, code: "MUTATED" } }
  end

  def test_mutating_lookup_medication_entry_raises_frozen_error
    register_sample("MH")
    medication = Corvid::MedicalFrailtyCriteria.lookup("MH").categories["synthetic_z9981"].medication_codes.first
    assert_raises(FrozenError) { medication[:code] = "MUTATED" }
  end

  private

  def minimal_categories
    {
      synthetic_z9981: {
        icd10_prefixes: [ "Z9981" ],
        medication_codes: [ { system: RX_SYSTEM, code: "RX_TEST_001" } ],
        procedure_codes: [ "HCPCS_TEST_A" ]
      }
    }
  end

  def register_sample(code)
    Corvid::MedicalFrailtyCriteria.register(code, categories: minimal_categories)
  end
end
