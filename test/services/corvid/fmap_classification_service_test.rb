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
        aian_verified: true,
        evidence_refs: [ "attestation:tok_example_aian" ]
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
        aian_verified: true,
        evidence_refs: [ "attestation:tok_example_aian" ]
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
        received_through_basis: "cca",
        evidence_refs: [ "cca_agreement:doc_example_1" ]
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
        evidence_refs: [ "attestation:tok_example_aian" ],
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

    # The governing invariant: an asserted input with no evidence behind
    # it must never buy the higher federal share.
    test "an unevidenced 100 percent is refused, not granted" do
      result = FmapClassificationService.classify(
        date_of_service: Date.new(2026, 3, 1),
        jurisdiction: "MT",
        facility_authority: @contract_638,
        aian_verified: true,
        evidence_refs: []
      )

      assert_equal "fmap_regular", result.category
      assert_equal FmapClassificationService::UNEVIDENCED_100, result.determination_reason
      assert_includes result.missing_evidence, "evidence_refs"
      assert_equal "fmap_100_ihs_638", result.best_available_category
      assert result.misclassification_gap?
    end

    test "classify! persists the refusal, never an unevidenced 100 percent row" do
      determination = FmapClassificationService.classify!(
        encounter_identifier: "enc_example_3",
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "AZ",
        facility_authority: @uio,
        aian_verified: true
      )

      assert_equal "fmap_regular", determination.category
      assert_equal FmapClassificationService::UNEVIDENCED_100, determination.determination_reason
      assert_empty determination.evidence_refs
    end

    test "a persisted 100 percent determination must name its evidence" do
      determination = FmapDetermination.new(
        encounter_identifier: "enc_example_4",
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "AZ",
        category: "fmap_100_uio",
        determined_at: Time.current
      )

      refute determination.valid?
      assert determination.errors[:evidence_refs].any?
    end

    # An unloaded rules table is a broken input, not a finding of "not
    # Medicaid": a CMS-64 run must see the refusal, not a complete-looking
    # under-claim.
    test "no rules in force yields undetermined, never a definitive category" do
      FmapRule.unscoped.delete_all

      result = FmapClassificationService.classify(
        date_of_service: Date.new(2026, 3, 1),
        jurisdiction: "MT",
        facility_authority: @contract_638,
        aian_verified: true,
        evidence_refs: [ "attestation:tok_example_aian" ]
      )

      assert_equal "undetermined", result.category
      assert result.undetermined?
      assert_equal FmapClassificationService::NO_RULES_IN_FORCE, result.determination_reason
      assert_nil result.fmap_percent
      assert_empty result.rule_citations
    end

    test "a date of service before every rule's window is undetermined" do
      result = FmapClassificationService.classify(
        date_of_service: Date.new(1960, 1, 1),
        jurisdiction: "MT",
        aian_verified: false
      )

      assert_equal "undetermined", result.category
      assert_equal FmapClassificationService::NO_RULES_IN_FORCE, result.determination_reason
    end

    test "an authority with no effective date is rejected, never in force forever" do
      undated = FacilityAuthority.new(
        facility_identifier: "fac_undated_example",
        authority_type: "contract_638"
      )

      refute undated.valid?
      assert undated.errors[:effective_on].any?
      refute undated.in_force_on?(Date.new(2018, 6, 1))
    end

    test "a date of service before the authority started confers no basis" do
      result = FmapClassificationService.classify(
        date_of_service: Date.new(2018, 6, 1),
        jurisdiction: "MT",
        facility_authority: @contract_638,
        aian_verified: true,
        evidence_refs: [ "attestation:tok_example_aian" ]
      )

      assert_equal "fmap_regular", result.category
    end
  end
end
