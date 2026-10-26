# frozen_string_literal: true

require "test_helper"

module Corvid
  # Issue #680 round 4: FmapClassificationService must canonicalize
  # jurisdiction with the same rule as StateMedicaidRules (two ASCII
  # letters, then upcase(:ascii)). Unicode lookalikes must not alias a
  # configured expansion state.
  class FmapJurisdictionCanonicalTest < ActiveSupport::TestCase
    TENANT = "tnt_test_jurisdiction_canonical"
    DOS = Date.new(2026, 3, 1)
    AIAN_EVIDENCE = { "supports" => "aian_status", "ref" => "attestation:tok_test_680_xi_aian" }.freeze
    DOTLESS_I_XI = "x\u0131"
    MALFORMED_JURISDICTIONS = [
      DOTLESS_I_XI,
      "\u017Fx",
      "\uFB00",
      "X",
      "XAA",
      "X1",
      "X-",
      "x\na",
      "\uFF38\uFF21"
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
            label: "jurisdiction input length #{jurisdiction_input.length}"
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
            label: "jurisdiction input length #{jurisdiction_input.length}"
          )
        end
      end
    end

    test "ascii surrounding whitespace still canonicalizes xa to XA for expansion lookup" do
      with_tenant(TENANT) do
        canonical = classify_expansion(jurisdiction: "XA")
        spaced = classify_expansion(jurisdiction: " xa ")
        lower = classify_expansion(jurisdiction: "xa")

        assert_equal "fmap_90_expansion", canonical.category
        assert_equal canonical.category, spaced.category
        assert_equal canonical.fmap_percent, spaced.fmap_percent
        assert_equal canonical.category, lower.category
        assert_equal canonical.fmap_percent, lower.fmap_percent
      end
    end

    test "classify! with dotless i jurisdiction raises without persisting and omits raw input from message" do
      with_tenant(TENANT) do
        before = FmapDetermination.count

        error = assert_raises(ArgumentError) do
          FmapClassificationService.classify!(
            encounter_identifier: "enc_test_680_xi_malformed",
            date_of_service: DOS,
            jurisdiction: DOTLESS_I_XI,
            coverage_group: "expansion_adult",
            aian_verified: false
          )
        end

        assert_equal before, FmapDetermination.count
        refute_includes error.message, "\u0131"
      end
    end

    private

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
  end
end
