# frozen_string_literal: true

require "minitest/autorun"
require "corvid/program_registry"

class Corvid::ProgramRegistryTest < Minitest::Test
  def setup
    Corvid::ProgramRegistry.reset!
  end

  def teardown
    Corvid::ProgramRegistry.reset!
  end

  # -- Built-in IHS programs are registered ------------------------------------

  def test_built_in_ihs_programs_are_present_after_reset
    %w[immunization sti tb neonatal lead hep_b communicable_disease].each do |code|
      assert Corvid::ProgramRegistry.exists?(code), "expected built-in program #{code}"
    end
  end

  def test_codes_returns_all_registered_codes
    codes = Corvid::ProgramRegistry.codes
    assert_includes codes, "tb"
    assert_includes codes, "hep_b"
  end

  # -- find --------------------------------------------------------------------

  def test_find_returns_entry_for_known_code
    entry = Corvid::ProgramRegistry.find("tb")
    refute_nil entry
    assert_equal "tb", entry.code
    assert_kind_of String, entry.display_name
    assert_kind_of Array, entry.milestones
  end

  def test_find_returns_nil_for_unknown_code
    assert_nil Corvid::ProgramRegistry.find("not_a_real_program")
  end

  def test_find_accepts_symbol_or_string
    assert_equal Corvid::ProgramRegistry.find("tb"), Corvid::ProgramRegistry.find(:tb)
  end

  # -- Built-in milestone ladders ---------------------------------------------

  def test_tb_program_carries_milestone_ladder
    keys = Corvid::ProgramRegistry.find("tb").milestones.map { |m| m[:key] }
    assert_equal %w[initial_skin_test chest_xray treatment_start followup_6mo], keys
  end

  def test_hep_b_program_carries_post_vaccination_test_at_270_days
    post = Corvid::ProgramRegistry.find("hep_b").milestones.find { |m| m[:key] == "post_vaccination_test" }
    refute_nil post
    assert_equal 270, post[:days_after_anchor]
  end

  def test_legacy_enum_only_programs_have_empty_milestones
    # Programs that existed in the old PROGRAM_TYPES enum but had no
    # MILESTONE_TEMPLATES entry (sti, neonatal, lead, communicable_disease)
    # remain registered with an empty milestone ladder so existing data passes
    # validation while clinical templates can be added later.
    %w[sti neonatal lead communicable_disease].each do |code|
      entry = Corvid::ProgramRegistry.find(code)
      refute_nil entry, "expected legacy enum program #{code} to be registered"
      assert_equal [], entry.milestones, "expected #{code} to have no milestones yet"
    end
  end

  # -- Host extension ----------------------------------------------------------

  def test_host_can_register_a_new_program
    Corvid::ProgramRegistry.register(
      "access_bh",
      display_name: "ACCESS Behavioral Health",
      milestones: [
        { key: "initial_phq9", description: "Initial PHQ-9", days_after_anchor: 0, required: true }
      ]
    )

    assert Corvid::ProgramRegistry.exists?("access_bh")
    entry = Corvid::ProgramRegistry.find("access_bh")
    assert_equal "ACCESS Behavioral Health", entry.display_name
    assert_equal "initial_phq9", entry.milestones.first[:key]
  end

  def test_register_does_not_lose_defaults
    Corvid::ProgramRegistry.register("custom_program", display_name: "Custom", milestones: [])
    assert Corvid::ProgramRegistry.exists?("tb"), "registering a custom program must not blow away IHS defaults"
    assert Corvid::ProgramRegistry.exists?("custom_program")
  end

  def test_register_overrides_existing_code
    Corvid::ProgramRegistry.register("tb", display_name: "Custom TB", milestones: [])
    assert_equal "Custom TB", Corvid::ProgramRegistry.find("tb").display_name
    assert_equal [], Corvid::ProgramRegistry.find("tb").milestones
  end

  def test_register_freezes_milestone_array
    Corvid::ProgramRegistry.register(
      "frozen_test",
      display_name: "Frozen Test",
      milestones: [{ key: "x", description: "x", days_after_anchor: 0, required: true }]
    )
    entry = Corvid::ProgramRegistry.find("frozen_test")
    assert entry.milestones.frozen?, "expected milestones array to be frozen"
  end

  # -- exists? -----------------------------------------------------------------

  def test_exists_returns_true_for_registered
    assert Corvid::ProgramRegistry.exists?("tb")
  end

  def test_exists_returns_false_for_unregistered
    refute Corvid::ProgramRegistry.exists?("not_real")
  end

  def test_exists_accepts_symbol
    assert Corvid::ProgramRegistry.exists?(:tb)
  end

  # -- Milestone normalization & validation -----------------------------------

  def test_register_accepts_string_keyed_milestones
    Corvid::ProgramRegistry.register(
      "string_keyed",
      display_name: "String Keyed",
      milestones: [
        { "key" => "step_one", "description" => "First", "days_after_anchor" => 0, "required" => true }
      ]
    )
    milestone = Corvid::ProgramRegistry.find("string_keyed").milestones.first
    assert_equal "step_one", milestone[:key]
    assert_equal "First", milestone[:description]
    assert_equal 0, milestone[:days_after_anchor]
    assert_equal true, milestone[:required]
  end

  def test_register_defaults_required_to_false_when_omitted
    Corvid::ProgramRegistry.register(
      "default_required",
      display_name: "Default Required",
      milestones: [{ key: "x", description: "x", days_after_anchor: 0 }]
    )
    assert_equal false, Corvid::ProgramRegistry.find("default_required").milestones.first[:required]
  end

  def test_register_raises_when_milestone_is_missing_key
    assert_raises(ArgumentError) do
      Corvid::ProgramRegistry.register(
        "missing_key",
        display_name: "Missing Key",
        milestones: [{ description: "no key", days_after_anchor: 0 }]
      )
    end
  end

  def test_register_raises_when_milestone_is_missing_description
    assert_raises(ArgumentError) do
      Corvid::ProgramRegistry.register(
        "missing_desc",
        display_name: "Missing Desc",
        milestones: [{ key: "x", days_after_anchor: 0 }]
      )
    end
  end

  def test_register_raises_when_milestone_is_missing_days_after_anchor
    assert_raises(ArgumentError) do
      Corvid::ProgramRegistry.register(
        "missing_days",
        display_name: "Missing Days",
        milestones: [{ key: "x", description: "x" }]
      )
    end
  end

  def test_register_raises_when_days_after_anchor_is_not_integer
    assert_raises(ArgumentError) do
      Corvid::ProgramRegistry.register(
        "bad_days",
        display_name: "Bad Days",
        milestones: [{ key: "x", description: "x", days_after_anchor: "soon" }]
      )
    end
  end

  def test_register_raises_when_required_is_not_boolean
    assert_raises(ArgumentError) do
      Corvid::ProgramRegistry.register(
        "bad_required",
        display_name: "Bad Required",
        milestones: [{ key: "x", description: "x", days_after_anchor: 0, required: "true" }]
      )
    end
  end

  def test_register_raises_when_milestone_is_not_a_hash
    assert_raises(ArgumentError) do
      Corvid::ProgramRegistry.register(
        "bad_shape",
        display_name: "Bad Shape",
        milestones: ["not a hash"]
      )
    end
  end

  def test_normalized_milestone_hashes_are_frozen
    Corvid::ProgramRegistry.register(
      "frozen_hashes",
      display_name: "Frozen Hashes",
      milestones: [{ key: "x", description: "x", days_after_anchor: 0, required: true }]
    )
    milestone = Corvid::ProgramRegistry.find("frozen_hashes").milestones.first
    assert milestone.frozen?, "expected milestone hash to be frozen"
  end

  # -- reset! / clear! ---------------------------------------------------------

  def test_reset_clears_host_registrations_but_restores_defaults
    Corvid::ProgramRegistry.register("custom", display_name: "Custom", milestones: [])
    assert Corvid::ProgramRegistry.exists?("custom")

    Corvid::ProgramRegistry.reset!

    refute Corvid::ProgramRegistry.exists?("custom"), "reset! should drop host registrations"
    assert Corvid::ProgramRegistry.exists?("tb"), "reset! should restore defaults"
  end

  def test_clear_drops_everything_including_defaults
    Corvid::ProgramRegistry.clear!
    refute Corvid::ProgramRegistry.exists?("tb")
    assert_equal [], Corvid::ProgramRegistry.codes
  end
end
