# frozen_string_literal: true

require "test_helper"

class Corvid::MedicaidRuleSetResolverTest < ActiveSupport::TestCase
  TENANT = "tnt_test"

  INDIAN_EXEMPTIONS = %w[eligible not_eligible unknown].freeze
  UNCONFIGURED_STATE_CODES = %w[ZZ x1].freeze

  # -- 3 × 4: exemption × eligibility group ----------------------------------

  test "resolve expansion_adult with eligible indian exemption on XA" do
    with_tenant(TENANT) do
      result = resolve(eligibility_group: "expansion_adult", state: "XA", indian_exemption: "eligible")

      assert_rule_set(
        result,
        renewal_cycle_months: 12,
        retroactive_window_months: 3,
        work_requirement: "exempt",
        exemption_needs_confirmation: false,
        reasons: [ "indian_exemption" ]
      )
    end
  end

  test "resolve expansion_adult with not_eligible indian exemption on XA" do
    with_tenant(TENANT) do
      result = resolve(eligibility_group: "expansion_adult", state: "XA", indian_exemption: "not_eligible")

      assert_rule_set(
        result,
        renewal_cycle_months: 12,
        retroactive_window_months: 3,
        work_requirement: "not_applicable",
        exemption_needs_confirmation: false,
        reasons: []
      )
    end
  end

  test "resolve expansion_adult with unknown indian exemption on XA" do
    with_tenant(TENANT) do
      result = resolve(eligibility_group: "expansion_adult", state: "XA", indian_exemption: "unknown")

      assert_rule_set(
        result,
        renewal_cycle_months: 12,
        retroactive_window_months: 3,
        work_requirement: "not_applicable",
        exemption_needs_confirmation: true,
        reasons: [ "indian_exemption_unconfirmed" ]
      )
    end
  end

  test "resolve waiver_adult with eligible indian exemption on XB" do
    with_tenant(TENANT) do
      result = resolve(eligibility_group: "waiver_adult", state: "XB", indian_exemption: "eligible")

      assert_rule_set(
        result,
        renewal_cycle_months: 12,
        retroactive_window_months: 2,
        work_requirement: "exempt",
        exemption_needs_confirmation: false,
        reasons: [ "indian_exemption" ]
      )
    end
  end

  test "resolve waiver_adult with not_eligible indian exemption on XB" do
    with_tenant(TENANT) do
      result = resolve(eligibility_group: "waiver_adult", state: "XB", indian_exemption: "not_eligible")

      assert_rule_set(
        result,
        renewal_cycle_months: 12,
        retroactive_window_months: 2,
        work_requirement: "applies",
        exemption_needs_confirmation: false,
        reasons: []
      )
    end
  end

  test "resolve waiver_adult with unknown indian exemption on XB" do
    with_tenant(TENANT) do
      result = resolve(eligibility_group: "waiver_adult", state: "XB", indian_exemption: "unknown")

      assert_rule_set(
        result,
        renewal_cycle_months: 12,
        retroactive_window_months: 2,
        work_requirement: "applies",
        exemption_needs_confirmation: true,
        reasons: [ "indian_exemption_unconfirmed" ]
      )
    end
  end

  test "resolve other with eligible indian exemption on XA" do
    with_tenant(TENANT) do
      result = resolve(eligibility_group: "other", state: "XA", indian_exemption: "eligible")

      assert_rule_set(
        result,
        renewal_cycle_months: 12,
        retroactive_window_months: 1,
        work_requirement: "exempt",
        exemption_needs_confirmation: false,
        reasons: [ "indian_exemption" ]
      )
    end
  end

  test "resolve other with not_eligible indian exemption on XA" do
    with_tenant(TENANT) do
      result = resolve(eligibility_group: "other", state: "XA", indian_exemption: "not_eligible")

      assert_rule_set(
        result,
        renewal_cycle_months: 24,
        retroactive_window_months: 1,
        work_requirement: "not_applicable",
        exemption_needs_confirmation: false,
        reasons: []
      )
    end
  end

  test "resolve other with unknown indian exemption on XA" do
    with_tenant(TENANT) do
      result = resolve(eligibility_group: "other", state: "XA", indian_exemption: "unknown")

      assert_rule_set(
        result,
        renewal_cycle_months: 24,
        retroactive_window_months: 1,
        work_requirement: "not_applicable",
        exemption_needs_confirmation: true,
        reasons: [ "indian_exemption_unconfirmed" ]
      )
    end
  end

  test "resolve unknown eligibility group with eligible indian exemption on XA" do
    with_tenant(TENANT) do
      result = resolve(eligibility_group: "unknown", state: "XA", indian_exemption: "eligible")

      assert_rule_set(
        result,
        renewal_cycle_months: nil,
        retroactive_window_months: nil,
        work_requirement: "undetermined",
        exemption_needs_confirmation: false,
        reasons: [ "eligibility_group_unknown" ]
      )
    end
  end

  test "resolve unknown eligibility group with not_eligible indian exemption on XA" do
    with_tenant(TENANT) do
      result = resolve(eligibility_group: "unknown", state: "XA", indian_exemption: "not_eligible")

      assert_rule_set(
        result,
        renewal_cycle_months: nil,
        retroactive_window_months: nil,
        work_requirement: "undetermined",
        exemption_needs_confirmation: false,
        reasons: [ "eligibility_group_unknown" ]
      )
    end
  end

  test "resolve unknown eligibility group with unknown indian exemption on XA" do
    with_tenant(TENANT) do
      result = resolve(eligibility_group: "unknown", state: "XA", indian_exemption: "unknown")

      assert_rule_set(
        result,
        renewal_cycle_months: nil,
        retroactive_window_months: nil,
        work_requirement: "undetermined",
        exemption_needs_confirmation: true,
        reasons: [ "eligibility_group_unknown", "indian_exemption_unconfirmed" ]
      )
    end
  end

  # -- State not configured ----------------------------------------------------

  INDIAN_EXEMPTIONS.each do |exemption|
    UNCONFIGURED_STATE_CODES.each do |state_code|
      test "resolve with #{exemption} indian exemption when state #{state_code} is not configured" do
        with_tenant(TENANT) do
          result = resolve(
            eligibility_group: "expansion_adult",
            state: state_code,
            indian_exemption: exemption
          )

          reasons = [
            "state_not_configured",
            ("indian_exemption_unconfirmed" if exemption == "unknown")
          ].compact

          assert_rule_set(
            result,
            renewal_cycle_months: nil,
            retroactive_window_months: nil,
            work_requirement: "undetermined",
            exemption_needs_confirmation: exemption == "unknown",
            reasons: reasons
          )
        end
      end
    end
  end

  # -- Eligibility group not configured for state ------------------------------

  INDIAN_EXEMPTIONS.each do |exemption|
    test "resolve waiver_adult with #{exemption} indian exemption when group is not configured on XA" do
      with_tenant(TENANT) do
        result = resolve(eligibility_group: "waiver_adult", state: "XA", indian_exemption: exemption)

        reasons = [
          "eligibility_group_not_configured",
          ("indian_exemption_unconfirmed" if exemption == "unknown")
        ].compact

        assert_rule_set(
          result,
          renewal_cycle_months: nil,
          retroactive_window_months: nil,
          work_requirement: "undetermined",
          exemption_needs_confirmation: exemption == "unknown",
          reasons: reasons
        )
      end
    end

    test "resolve expansion_adult with #{exemption} indian exemption when group is not configured on XB" do
      with_tenant(TENANT) do
        result = resolve(eligibility_group: "expansion_adult", state: "XB", indian_exemption: exemption)

        reasons = [
          "eligibility_group_not_configured",
          ("indian_exemption_unconfirmed" if exemption == "unknown")
        ].compact

        assert_rule_set(
          result,
          renewal_cycle_months: nil,
          retroactive_window_months: nil,
          work_requirement: "undetermined",
          exemption_needs_confirmation: exemption == "unknown",
          reasons: reasons
        )
      end
    end
  end

  # -- Indian exemption overrides group renewal and work requirement -----------

  test "resolve eligible expansion adult on XC uses twelve month renewal and exempt work requirement" do
    with_tenant(TENANT) do
      register_synthetic_xc!
      result = resolve(eligibility_group: "expansion_adult", state: "XC", indian_exemption: "eligible")

      assert_rule_set(
        result,
        renewal_cycle_months: 12,
        retroactive_window_months: 1,
        work_requirement: "exempt",
        exemption_needs_confirmation: false,
        reasons: [ "indian_exemption" ]
      )
    end
  ensure
    restore_state_medicaid_rules!
  end

  # -- Unknown exemption never implies applies without confirmation ------------

  test "resolve with unknown indian exemption never yields applies without exemption_needs_confirmation" do
    with_tenant(TENANT) do
      register_synthetic_xc!

      scenarios = [
        { eligibility_group: "expansion_adult", state: "XA" },
        { eligibility_group: "expansion_adult", state: "XC" },
        { eligibility_group: "waiver_adult", state: "XB" },
        { eligibility_group: "other", state: "XA" },
        { eligibility_group: "other", state: "XB" },
        { eligibility_group: "waiver_adult", state: "XA" },
        { eligibility_group: "expansion_adult", state: "XB" },
        { eligibility_group: "unknown", state: "XA" },
        { eligibility_group: "expansion_adult", state: "ZZ" }
      ]

      scenarios.each do |attrs|
        result = resolve(**attrs, indian_exemption: "unknown")
        if result.work_requirement == "applies"
          assert result.exemption_needs_confirmation,
                 "expected confirmation for #{attrs.inspect} but got #{result.inspect}"
        end
      end
    end
  ensure
    restore_state_medicaid_rules!
  end

  # -- Immutability ------------------------------------------------------------

  test "resolve returns frozen MedicaidRuleSet and frozen reasons" do
    with_tenant(TENANT) do
      result = resolve(eligibility_group: "expansion_adult", state: "XA", indian_exemption: "eligible")

      assert_instance_of Corvid::MedicaidRuleSet, result
      assert result.frozen?
      assert result.reasons.frozen?
      result.reasons.each { |reason| assert reason.frozen? }
      assert_raises(FrozenError) { result.reasons << "mutated" }
    end
  end

  # -- token_characters: String.new pins own characters (#680) ---------------

  test "resolve string subclass is_a Symbol spoof for waiver_adult uses six month waiver rules on XC" do
    with_tenant(TENANT) do
      register_synthetic_xc_dual_groups!
      spoof = string_subclass_waiver_adult_is_a_symbol_spoof_expansion
      result = resolve(eligibility_group: spoof, state: "XC", indian_exemption: "not_eligible")

      assert_rule_set(
        result,
        renewal_cycle_months: 6,
        retroactive_window_months: 1,
        work_requirement: "applies",
        exemption_needs_confirmation: false,
        reasons: []
      )
    end
  ensure
    restore_state_medicaid_rules!
  end

  test "resolve object is_a Symbol group spoof raises eligibility_group is not recognized" do
    with_tenant(TENANT) do
      register_synthetic_xc_dual_groups!
      spoof = object_is_a_symbol_spoof_expansion_adult

      error = assert_raises(ArgumentError) do
        resolve(eligibility_group: spoof, state: "XC", indian_exemption: "not_eligible")
      end

      assert_equal "eligibility_group is not recognized", error.message
      refute_includes error.message, "expansion_adult"
    end
  ensure
    restore_state_medicaid_rules!
  end

  # -- Symbol inputs -----------------------------------------------------------

  test "resolve accepts symbol eligibility_group state and indian_exemption" do
    with_tenant(TENANT) do
      result = resolve(
        eligibility_group: :waiver_adult,
        state: :xb,
        indian_exemption: :not_eligible
      )

      assert_rule_set(
        result,
        renewal_cycle_months: 12,
        retroactive_window_months: 2,
        work_requirement: "applies",
        exemption_needs_confirmation: false,
        reasons: []
      )
    end
  end

  # -- ArgumentError -----------------------------------------------------------

  test "resolve raises ArgumentError for invalid eligibility_group without echoing the value" do
    with_tenant(TENANT) do
      [ nil, "", "Eligible", 1, "invalid_group" ].each do |bad_group|
        error = assert_raises(ArgumentError) do
          resolve(eligibility_group: bad_group, state: "XA", indian_exemption: "not_eligible")
        end
        refute_includes error.message, bad_group.to_s unless bad_group.to_s.empty?
      end
    end
  end

  test "resolve raises ArgumentError for invalid indian_exemption without echoing the value" do
    with_tenant(TENANT) do
      [ nil, "", "Eligible", 1, "maybe" ].each do |bad_exemption|
        error = assert_raises(ArgumentError) do
          resolve(eligibility_group: "other", state: "XA", indian_exemption: bad_exemption)
        end
        refute_includes error.message, bad_exemption.to_s unless bad_exemption.to_s.empty?
      end
    end
  end

  private

  def resolve(eligibility_group:, state:, indian_exemption:)
    Corvid::MedicaidRuleSetResolver.resolve(
      eligibility_group: eligibility_group,
      state: state,
      indian_exemption: indian_exemption
    )
  end

  def assert_rule_set(result, renewal_cycle_months:, retroactive_window_months:, work_requirement:,
                      exemption_needs_confirmation:, reasons:)
    assert_instance_of Corvid::MedicaidRuleSet, result
    assert_equal_or_nil renewal_cycle_months, result.renewal_cycle_months
    assert_equal_or_nil retroactive_window_months, result.retroactive_window_months
    assert_equal work_requirement, result.work_requirement
    assert_equal exemption_needs_confirmation, result.exemption_needs_confirmation
    assert_equal reasons, result.reasons
  end

  # Minitest 6 rejects assert_equal(nil, ...); expected nil must be stated explicitly.
  def assert_equal_or_nil(expected, actual)
    expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
  end

  def register_synthetic_xc!
    Corvid::StateMedicaidRules.register(
      "XC",
      expanded: true,
      groups: {
        expansion_adult: {
          renewal_months: 6,
          retro_coverage_months: 1,
          work_requirement: true
        }
      }
    )
  end

  def register_synthetic_xc_dual_groups!
    Corvid::StateMedicaidRules.register(
      "XC",
      expanded: true,
      work_requirement_programs: [
        { code: "xc_synthetic_waiver", description_pattern: /\bSYNTHETIC XC WAIVER\b/i }
      ],
      groups: {
        expansion_adult: {
          renewal_months: 12,
          retro_coverage_months: 1,
          work_requirement: false
        },
        waiver_adult: {
          renewal_months: 6,
          retro_coverage_months: 1,
          work_requirement: true
        }
      }
    )
  end

  def string_subclass_waiver_adult_is_a_symbol_spoof_expansion
    Class.new(String) do
      def is_a?(type)
        return true if type == Symbol

        super
      end

      def name
        "expansion_adult"
      end
    end.new("waiver_adult")
  end

  def object_is_a_symbol_spoof_expansion_adult
    Object.new.tap do |value|
      value.define_singleton_method(:is_a?) do |type|
        return true if type == Symbol

        super(type)
      end
      value.define_singleton_method(:name) { "expansion_adult" }
    end
  end

  def restore_state_medicaid_rules!
    Corvid::StateMedicaidRules.reset!
    load Rails.root.join("config/initializers/corvid_state_medicaid_rules.rb")
  end
end
