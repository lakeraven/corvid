# frozen_string_literal: true

require "test_helper"

module Corvid
  # Issue #680: FmapClassificationService must canonicalize jurisdiction with
  # the same rule as StateMedicaidRules (own String characters or Symbol#name,
  # two ASCII letters, then upcase(:ascii)). Unicode lookalikes, encoding
  # variants, and String#to_s overrides must not alias a configured state.
  class FmapJurisdictionCanonicalTest < ActiveSupport::TestCase
    TENANT = "tnt_test_jurisdiction_canonical"
    DOS = Date.new(2026, 3, 1)
    AIAN_EVIDENCE = { "supports" => "aian_status", "ref" => "attestation:tok_test_680_xi_aian" }.freeze
    DOTLESS_I_XI = "x\u0131"
    INVALID_UTF8_X_FF = String.new("X\xFF".b).force_encoding("UTF-8")
    UTF16LE_XA = "XA".encode("UTF-16LE")
    BINARY_NON_ASCII_X_C3 = "X\xC3".b
    NON_CODE_JURISDICTION_OBJECT = Object.new.tap do |value|
      value.define_singleton_method(:to_s) { "xa" }
    end
    MALFORMED_JURISDICTIONS = [
      DOTLESS_I_XI,
      "\u017Fx",
      "\uFB00",
      "X",
      "XAA",
      "X1",
      "X-",
      "x\na",
      "\uFF38\uFF21",
      "XA\u0000",
      "\u00A0XA",
      INVALID_UTF8_X_FF,
      UTF16LE_XA,
      BINARY_NON_ASCII_X_C3
    ].freeze
    NON_CODE_JURISDICTION_INPUTS = [
      NON_CODE_JURISDICTION_OBJECT,
      12,
      %w[X A]
    ].freeze

    setup do
      FmapRuleLoader.load_defaults!
      register_xi_expansion_state!
      with_tenant(TENANT) do
        @contract_638 = FacilityAuthority.create!(
          facility_identifier: "fac_test_680_xi_638",
          authority_type: "contract_638",
          air_eligible: true,
          effective_on: Date.new(2020, 1, 1)
        )
      end
    end

    teardown do
      restore_state_medicaid_rules!
    end

    test "registered XI expansion grants 90 percent for ascii xi and XI" do
      with_tenant(TENANT) do
        lower = classify_expansion(jurisdiction: "xi")
        upper = classify_expansion(jurisdiction: "XI")

        assert_equal "fmap_90_expansion", lower.category
        assert_equal 90.0, lower.fmap_percent
        assert_equal lower.category, upper.category
        assert_equal lower.fmap_percent, upper.fmap_percent
      end
    end

    test "dotless i jurisdiction does not alias to registered XI expansion state" do
      refute Corvid::StateMedicaidRules.lookup(DOTLESS_I_XI).configured?

      with_tenant(TENANT) do
        result = classify_expansion(jurisdiction: DOTLESS_I_XI)

        assert_malformed_jurisdiction_undetermined(result)
        refute_equal "fmap_90_expansion", result.category
      end
    end

    test "malformed jurisdiction values are undetermined with no_matching_rule and no tier" do
      with_tenant(TENANT) do
        MALFORMED_JURISDICTIONS.each do |jurisdiction_input|
          result = classify_expansion(jurisdiction: jurisdiction_input)

          assert_malformed_jurisdiction_undetermined(
            result,
            label: malformed_label(jurisdiction_input)
          )
        end
      end
    end

    test "malformed jurisdiction refuses 100 percent tier even with contract 638 authority and AIAN evidence" do
      with_tenant(TENANT) do
        MALFORMED_JURISDICTIONS.each do |jurisdiction_input|
          result = classify_with_full_hundred_evidence(jurisdiction: jurisdiction_input)

          assert_malformed_jurisdiction_undetermined(
            result,
            label: malformed_label(jurisdiction_input)
          )
        end
      end
    end

    test "ascii surrounding whitespace still canonicalizes xa to XA for expansion lookup" do
      with_tenant(TENANT) do
        canonical = classify_expansion(jurisdiction: "XA")
        spaced = classify_expansion(jurisdiction: " xa ")
        lower = classify_expansion(jurisdiction: "xa")
        binary_ascii = classify_expansion(jurisdiction: "xa".b)

        assert_equal "fmap_90_expansion", canonical.category
        assert_equal canonical.category, spaced.category
        assert_equal canonical.fmap_percent, spaced.fmap_percent
        assert_equal canonical.category, lower.category
        assert_equal canonical.fmap_percent, lower.fmap_percent
        assert_equal canonical.category, binary_ascii.category
        assert_equal canonical.fmap_percent, binary_ascii.fmap_percent
      end
    end

    test "symbol jurisdiction canonicalizes like StateMedicaidRules lookup" do
      with_tenant(TENANT) do
        result = classify_expansion(jurisdiction: :xa)

        assert_equal "fmap_90_expansion", result.category
        assert_equal 90.0, result.fmap_percent
      end
    end

    test "string subclass own characters resolve XB not to_s XA alias for expansion_adult" do
      jurisdiction = jurisdiction_string_subclass_xb_to_s_xa

      with_tenant(TENANT) do
        result = classify_expansion(jurisdiction: jurisdiction)

        assert_expansion_state_not_configured(result)
        refute_equal "fmap_90_expansion", result.category
      end
    end

    test "classify! persists XB for string subclass own characters not to_s XA" do
      jurisdiction = jurisdiction_string_subclass_xb_to_s_xa

      with_tenant(TENANT) do
        determination = FmapClassificationService.classify!(
          encounter_identifier: "enc_test_680_jurisdiction_spoof_xb",
          date_of_service: DOS,
          jurisdiction: jurisdiction,
          coverage_group: "expansion_adult",
          aian_verified: false
        )

        assert determination.persisted?
        assert_equal "XB", determination.jurisdiction
        assert_expansion_state_not_configured_determination(determination)
      end
    end

    test "non string non symbol jurisdiction inputs are malformed without persisting on classify!" do
      with_tenant(TENANT) do
        NON_CODE_JURISDICTION_INPUTS.each_with_index do |jurisdiction_input, index|
          result = classify_expansion(jurisdiction: jurisdiction_input)

          assert_malformed_jurisdiction_undetermined(
            result,
            label: "non-code input #{index}"
          )

          before = FmapDetermination.count
          assert_raises(ArgumentError) do
            FmapClassificationService.classify!(
              encounter_identifier: "enc_test_680_jurisdiction_non_code_#{index}",
              date_of_service: DOS,
              jurisdiction: jurisdiction_input,
              coverage_group: "expansion_adult",
              aian_verified: false
            )
          end
          assert_equal before, FmapDetermination.count
        end
      end
    end

    test "classify! with malformed jurisdictions raises without persisting" do
      with_tenant(TENANT) do
        MALFORMED_JURISDICTIONS.each_with_index do |jurisdiction_input, index|
          before = FmapDetermination.count

          error = assert_raises(ArgumentError) do
            FmapClassificationService.classify!(
              encounter_identifier: "enc_test_680_jurisdiction_malformed_#{index}",
              date_of_service: DOS,
              jurisdiction: jurisdiction_input,
              coverage_group: "expansion_adult",
              aian_verified: false
            )
          end

          assert_equal before, FmapDetermination.count
          refute_includes error.message, "\u0131" if jurisdiction_input == DOTLESS_I_XI
        end
      end
    end

    private

    def jurisdiction_string_subclass_xb_to_s_xa
      spoof = Class.new(String) { def to_s = "XA" }
      spoof.new("XB")
    end

    def register_xi_expansion_state!
      Corvid::StateMedicaidRules.register(
        "XI",
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

    def restore_state_medicaid_rules!
      Corvid::StateMedicaidRules.reset!
      load Rails.root.join("config/initializers/corvid_state_medicaid_rules.rb")
    end

    def classify_expansion(jurisdiction:, **overrides)
      FmapClassificationService.classify(
        date_of_service: DOS,
        jurisdiction: jurisdiction,
        coverage_group: "expansion_adult",
        aian_verified: false,
        **overrides
      )
    end

    def classify_with_full_hundred_evidence(jurisdiction:)
      FmapClassificationService.classify(
        date_of_service: DOS,
        jurisdiction: jurisdiction,
        coverage_group: "expansion_adult",
        facility_authority: @contract_638,
        aian_verified: true,
        evidence_refs: [ AIAN_EVIDENCE ]
      )
    end

    def malformed_label(jurisdiction_input)
      if jurisdiction_input.is_a?(String)
        "jurisdiction encoding #{jurisdiction_input.encoding.name} length #{jurisdiction_input.length}"
      else
        "jurisdiction input #{jurisdiction_input.class}"
      end
    end

    def assert_malformed_jurisdiction_undetermined(result, label: nil)
      prefix = label ? "#{label}: " : ""

      assert result.undetermined?, "#{prefix}expected undetermined"
      assert_equal FmapClassificationService::UNDETERMINED, result.category, prefix
      assert_equal FmapClassificationService::NO_MATCHING_RULE, result.determination_reason, prefix
      assert_nil result.fmap_percent, prefix
      assert_nil result.rule_key, prefix
      assert_nil result.best_available_category, prefix
      refute_equal "fmap_90_expansion", result.category, prefix
      refute_equal "fmap_100_ihs_638", result.category, prefix
    end

    def assert_expansion_state_not_configured(result)
      assert result.undetermined?
      assert_equal FmapClassificationService::UNDETERMINED, result.category
      assert_nil result.fmap_percent
      assert_nil result.rule_key
      assert_equal FmapClassificationService::EXPANSION_STATE_NOT_CONFIGURED, result.determination_reason
      assert_nil result.best_available_category
      refute_equal "fmap_90_expansion", result.category
    end

    def assert_expansion_state_not_configured_determination(determination)
      assert_equal FmapClassificationService::UNDETERMINED, determination.category
      assert_equal FmapClassificationService::EXPANSION_STATE_NOT_CONFIGURED, determination.determination_reason
      assert_nil determination.best_available_category
    end
  end
end
