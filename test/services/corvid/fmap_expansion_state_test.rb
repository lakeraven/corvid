# frozen_string_literal: true

require "test_helper"

module Corvid
  # Issue #680: the 90% expansion FMAP tier requires the jurisdiction to be
  # registered as an expansion state in StateMedicaidRules, not only
  # expansion_adult on the encounter.
  class FmapExpansionStateTest < ActiveSupport::TestCase
    TENANT = "tnt_test"
    AIAN_EVIDENCE = { "supports" => "aian_status", "ref" => "attestation:tok_test_680_aian" }.freeze
    DOS = Date.new(2026, 3, 1)

    setup do
      FmapRuleLoader.load_defaults!
      with_tenant(TENANT) do
        @contract_638 = FacilityAuthority.create!(
          facility_identifier: "fac_test_680_638",
          authority_type: "contract_638",
          air_eligible: true,
          effective_on: Date.new(2020, 1, 1)
        )
      end
    end

    test "XA expansion state grants 90 percent for expansion_adult without a 100 percent basis" do
      with_tenant(TENANT) do
        result = classify_expansion(jurisdiction: "XA")

        assert_equal "fmap_90_expansion", result.category
        assert_equal 90.0, result.fmap_percent
      end
    end

    test "XB configured but not expanded refuses 90 percent for expansion_adult" do
      with_tenant(TENANT) do
        result = classify_expansion(jurisdiction: "XB")

        assert_equal FmapClassificationService::UNDETERMINED, result.category
        assert result.undetermined?
        assert_nil result.fmap_percent
        assert_nil result.rule_key
        assert_empty result.rule_citations
        assert_equal FmapClassificationService::EXPANSION_STATE_NOT_CONFIGURED, result.determination_reason
        refute_equal "fmap_90_expansion", result.best_available_category
      end
    end

    test "unregistered XC refuses 90 percent for expansion_adult" do
      with_tenant(TENANT) do
        refute Corvid::StateMedicaidRules.lookup("XC").configured?

        result = classify_expansion(jurisdiction: "XC")

        assert_equal FmapClassificationService::UNDETERMINED, result.category
        assert result.undetermined?
        assert_nil result.fmap_percent
        assert_equal FmapClassificationService::EXPANSION_STATE_NOT_CONFIGURED, result.determination_reason
        refute_equal "fmap_90_expansion", result.category
        refute_equal "fmap_regular", result.category
        refute_equal "fmap_90_expansion", result.best_available_category
      end
    end

    test "lowercase jurisdiction matches canonical state code for expansion lookup" do
      entry = Corvid::StateMedicaidRules.lookup("xa")
      assert entry.configured?
      assert entry.expanded?

      with_tenant(TENANT) do
        canonical = classify_expansion(jurisdiction: "XA")
        lower = classify_expansion(jurisdiction: "xa")

        assert_equal canonical.category, lower.category
        assert_equal canonical.fmap_percent, lower.fmap_percent
        assert_equal "fmap_90_expansion", lower.category
      end
    end

    test "100 percent IHS 638 tier is unaffected in a non-expansion state" do
      with_tenant(TENANT) do
        result = FmapClassificationService.classify(
          date_of_service: DOS,
          jurisdiction: "XB",
          facility_authority: @contract_638,
          aian_verified: true,
          evidence_refs: [ AIAN_EVIDENCE ],
          coverage_group: "expansion_adult"
        )

        assert_equal "fmap_100_ihs_638", result.category
      end
    end

    test "unevidenced 100 percent fallback does not grant 90 percent in a non-expansion state" do
      with_tenant(TENANT) do
        xb = FmapClassificationService.classify(
          date_of_service: DOS,
          jurisdiction: "XB",
          facility_authority: @contract_638,
          aian_verified: true,
          evidence_refs: [],
          coverage_group: "expansion_adult"
        )

        refute_equal "fmap_90_expansion", xb.category
        assert xb.undetermined?

        xa = FmapClassificationService.classify(
          date_of_service: DOS,
          jurisdiction: "XA",
          facility_authority: @contract_638,
          aian_verified: true,
          evidence_refs: [],
          coverage_group: "expansion_adult"
        )

        assert_equal "fmap_90_expansion", xa.category
      end
    end

    test "REASONS includes expansion_state_not_configured" do
      assert_includes FmapClassificationService::REASONS, "expansion_state_not_configured"
      assert_equal "expansion_state_not_configured", FmapClassificationService::EXPANSION_STATE_NOT_CONFIGURED
    end

    test "classify! persists undetermined XB expansion_adult with expansion_state_not_configured" do
      with_tenant(TENANT) do
        determination = FmapClassificationService.classify!(
          encounter_identifier: "enc_test_680_xb",
          date_of_service: DOS,
          jurisdiction: "XB",
          coverage_group: "expansion_adult",
          aian_verified: false
        )

        assert determination.persisted?
        assert_equal FmapClassificationService::UNDETERMINED, determination.category
        assert_equal FmapClassificationService::EXPANSION_STATE_NOT_CONFIGURED, determination.determination_reason
      end
    end

    test "classification does not mutate StateMedicaidRules or FmapRule rows" do
      with_tenant(TENANT) do
        xb_entry = Corvid::StateMedicaidRules.lookup("XB")
        assert xb_entry.configured?
        refute xb_entry.expanded?

        rule_snapshot = FmapRule.order(:id).pluck(:id, :rule_key, :category, :updated_at)

        classify_expansion(jurisdiction: "XB")

        assert_equal false, Corvid::StateMedicaidRules.lookup("XB").expanded?
        assert_equal rule_snapshot, FmapRule.order(:id).pluck(:id, :rule_key, :category, :updated_at)
      end
    end

    private

    def classify_expansion(jurisdiction:, **overrides)
      FmapClassificationService.classify(
        date_of_service: DOS,
        jurisdiction: jurisdiction,
        coverage_group: "expansion_adult",
        aian_verified: false,
        **overrides
      )
    end
  end
end
