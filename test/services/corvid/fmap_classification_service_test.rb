# frozen_string_literal: true

require "test_helper"

module Corvid
  class FmapClassificationServiceTest < ActiveSupport::TestCase
    setup do
      Corvid::TenantContext.current_tenant_identifier = "tnt_example"
      FmapRuleLoader.load_defaults!
      @uio = FacilityAuthority.create!(
        facility_identifier: "fac_uio_example",
        authority_type: "uio",
        air_eligible: true,
        effective_on: Date.new(2020, 1, 1)
      )
      @contract_638 = FacilityAuthority.create!(
        facility_identifier: "fac_638_example",
        authority_type: "contract_638",
        air_eligible: true,
        effective_on: Date.new(2020, 1, 1)
      )
    end

    # The #546 acceptance spot-check: same encounter, different date of
    # service, different statute in force.
    test "UIO encounter inside the ARPA window is 100 percent; after it, regular" do
      inside = FmapClassificationService.classify(
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "AZ",
        facility_authority: @uio,
        aian_verified: true
      )
      assert_equal "fmap_100_uio", inside.category
      assert_equal "us-arpa-9815-uio-100", inside.rule_key
      assert_equal 100.0, inside.fmap_percent

      after = FmapClassificationService.classify(
        date_of_service: Date.new(2024, 6, 1),
        jurisdiction: "AZ",
        facility_authority: @uio,
        aian_verified: true
      )
      assert_equal "fmap_regular", after.category
    end

    test "638 encounter with AIAN evidence is 100 percent under 1905(b)" do
      result = FmapClassificationService.classify(
        date_of_service: Date.new(2026, 3, 1),
        jurisdiction: "MT",
        facility_authority: @contract_638,
        aian_verified: true
      )
      assert_equal "fmap_100_ihs_638", result.category
      assert result.rule_citations.first.include?("1905(b)")
      refute result.misclassification_gap?
    end

    test "missing AIAN evidence downgrades visibly, naming the gap" do
      result = FmapClassificationService.classify(
        date_of_service: Date.new(2026, 3, 1),
        jurisdiction: "MT",
        facility_authority: @contract_638,
        aian_verified: false
      )
      assert_equal "fmap_regular", result.category
      assert_equal "fmap_100_ihs_638", result.best_available_category
      assert_includes result.missing_evidence, "aian_attestation"
      assert result.misclassification_gap?
    end

    test "state share delta is computed only when both percents are known" do
      # Expansion-group encounter without AIAN evidence: 90 vs best 100.
      gap = FmapClassificationService.classify(
        date_of_service: Date.new(2026, 3, 1),
        jurisdiction: "MT",
        facility_authority: @contract_638,
        aian_verified: false,
        coverage_group: "expansion",
        billed_amount_cents: 10_000
      )
      assert_equal "fmap_90_expansion", gap.category
      assert_equal "fmap_100_ihs_638", gap.best_available_category
      assert_equal 1_000, gap.state_share_delta_cents

      # Regular fallback carries no percent: delta unknown, never guessed.
      unknown = FmapClassificationService.classify(
        date_of_service: Date.new(2026, 3, 1),
        jurisdiction: "MT",
        facility_authority: @contract_638,
        aian_verified: false,
        billed_amount_cents: 10_000
      )
      assert_nil unknown.state_share_delta_cents
    end

    test "CCA basis reaches 100 percent without an IHS/638 billing facility" do
      result = FmapClassificationService.classify(
        date_of_service: Date.new(2026, 3, 1),
        jurisdiction: "WA",
        aian_verified: true,
        received_through_basis: "cca"
      )
      assert_equal "fmap_100_cca", result.category
    end

    test "an expired facility authority does not confer a basis" do
      lapsed = FacilityAuthority.create!(
        facility_identifier: "fac_lapsed_example",
        authority_type: "contract_638",
        effective_on: Date.new(2020, 1, 1),
        expires_on: Date.new(2023, 12, 31)
      )
      result = FmapClassificationService.classify(
        date_of_service: Date.new(2026, 3, 1),
        jurisdiction: "MT",
        facility_authority: lapsed,
        aian_verified: true
      )
      assert_equal "fmap_regular", result.category
    end

    test "classify! persists an audit-defensible determination" do
      determination = FmapClassificationService.classify!(
        encounter_identifier: "enc_example_1",
        person_identifier: "per_example_1",
        facility_identifier: "fac_uio_example",
        evidence_refs: [ "attestation:tok_example_aian" ],
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "AZ",
        facility_authority: @uio,
        aian_verified: true
      )
      assert determination.persisted?
      assert_equal "fmap_100_uio", determination.category
      assert_equal [ "ARPA sec. 9815 (Pub. L. 117-2)" ], determination.rule_citations
      assert_equal [ "attestation:tok_example_aian" ], determination.evidence_refs
    end

    test "a claimed determination is immutable and corrections append" do
      determination = FmapClassificationService.classify!(
        encounter_identifier: "enc_example_2",
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "AZ",
        facility_authority: @uio,
        aian_verified: true,
        claim_reference: "clm_example_1"
      )

      determination.category = "non_medicaid"
      assert_raises(ActiveRecord::RecordInvalid) { determination.save! }
      determination.reload

      correction = determination.supersede_with!(category: "fmap_regular", fmap_percent: nil, rule_key: nil)
      assert_equal correction.id, determination.reload.superseded_by_id
      assert_equal "fmap_100_uio", determination.category
      assert_equal "fmap_regular", correction.category
      assert_includes FmapDetermination.current, correction
      refute_includes FmapDetermination.current, determination
    end
  end
end
