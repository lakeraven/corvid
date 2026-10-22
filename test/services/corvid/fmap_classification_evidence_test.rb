# frozen_string_literal: true

require "test_helper"

module Corvid
  # Pins the evidence chain behind a 100 percent FMAP determination (#547
  # review): the authority must be the encounter facility's own, each
  # requirement of the applied rule must have its own evidence, and the
  # persisted row must carry the basis and authority it was decided on.
  class FmapClassificationEvidenceTest < ActiveSupport::TestCase
    AIAN_EVIDENCE = { "supports" => "aian_status", "ref" => "attestation:tok_example_aian" }.freeze

    setup do
      Corvid::TenantContext.current_tenant_identifier = "tnt_example"
      FmapRuleLoader.load_defaults!
      @contract_638 = FacilityAuthority.create!(
        facility_identifier: "fac_638_example",
        authority_type: "contract_638",
        effective_on: Date.new(2020, 1, 1)
      )
      @uio = FacilityAuthority.create!(
        facility_identifier: "fac_uio_example",
        authority_type: "uio",
        effective_on: Date.new(2020, 1, 1)
      )
    end

    def classify_638(**overrides)
      FmapClassificationService.classify(
        date_of_service: Date.new(2026, 3, 1),
        jurisdiction: "XA",
        facility_authority: @contract_638,
        aian_verified: true,
        evidence_refs: [ AIAN_EVIDENCE ],
        **overrides
      )
    end

    test "an authority held by another facility is rejected, not applied" do
      assert_raises(ArgumentError) do
        FmapClassificationService.classify!(
          encounter_identifier: "enc_example_10",
          facility_identifier: "fac_plain_example",
          date_of_service: Date.new(2026, 3, 1),
          jurisdiction: "XA",
          facility_authority: @contract_638,
          aian_verified: true,
          evidence_refs: [ AIAN_EVIDENCE ]
        )
      end
      assert_equal 0, FmapDetermination.count
    end

    test "the determination records the authority's facility when none is given" do
      determination = FmapClassificationService.classify!(
        encounter_identifier: "enc_example_11",
        date_of_service: Date.new(2026, 3, 1),
        jurisdiction: "XA",
        facility_authority: @contract_638,
        aian_verified: true,
        evidence_refs: [ AIAN_EVIDENCE ]
      )
      assert_equal "fac_638_example", determination.facility_identifier
    end

    test "an unsaved authority confers no basis" do
      unsaved = FacilityAuthority.new(
        facility_identifier: "fac_638_example",
        authority_type: "contract_638",
        effective_on: Date.new(2020, 1, 1)
      )
      assert_raises(ArgumentError) { classify_638(facility_authority: unsaved) }
    end

    test "an authority from another tenant is rejected" do
      Corvid::TenantContext.current_tenant_identifier = "tnt_other_example"
      other = FacilityAuthority.create!(
        facility_identifier: "fac_638_example",
        authority_type: "contract_638",
        effective_on: Date.new(2020, 1, 1)
      )
      Corvid::TenantContext.current_tenant_identifier = "tnt_example"

      assert_raises(ArgumentError) { classify_638(facility_authority: other) }
    end

    test "classification reads the stored authority, not an in-memory edit" do
      fqhc = FacilityAuthority.create!(
        facility_identifier: "fac_fqhc_example",
        authority_type: "fqhc",
        effective_on: Date.new(2020, 1, 1)
      )
      fqhc.authority_type = "contract_638"

      result = classify_638(facility_authority: fqhc)
      assert_equal "fmap_regular", result.category
    end

    test "a CCA basis is never granted until an agreement can be verified" do
      result = FmapClassificationService.classify(
        date_of_service: Date.new(2026, 3, 1),
        jurisdiction: "XA",
        aian_verified: true,
        received_through_basis: "cca",
        evidence_refs: [ AIAN_EVIDENCE ]
      )
      refute_equal "fmap_100_cca", result.category
      assert_equal "fmap_100_cca", result.best_available_category
      assert_includes result.missing_evidence, "care_coordination_agreement"
    end

    test "evidence that does not support the AIAN status cannot buy 100 percent" do
      result = classify_638(
        evidence_refs: [ { "supports" => "aian_status", "ref" => "" } ]
      )
      assert_equal "fmap_regular", result.category
      assert_includes result.missing_evidence, "aian_status_evidence"
    end

    test "an untyped evidence reference is rejected" do
      assert_raises(ArgumentError) { classify_638(evidence_refs: [ "unrelated-doc" ]) }
    end

    test "a caller cannot supply the received-through evidence itself" do
      assert_raises(ArgumentError) do
        classify_638(
          evidence_refs: [ AIAN_EVIDENCE, { "supports" => "received_through", "ref" => "facility_authority:999" } ]
        )
      end
    end

    test "missing evidence names every gap to the best tier" do
      result = classify_638(aian_verified: false, evidence_refs: [])
      assert_equal "fmap_100_ihs_638", result.best_available_category
      assert_includes result.missing_evidence, "aian_attestation"
      assert_includes result.missing_evidence, "aian_status_evidence"
    end

    test "a UIO encounter in the ARPA window needs AIAN evidence like a 638 one" do
      result = FmapClassificationService.classify(
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "XA",
        facility_authority: @uio,
        aian_verified: false
      )
      assert_equal "fmap_regular", result.category
      assert_equal "fmap_100_uio", result.best_available_category
      assert_includes result.missing_evidence, "aian_attestation"
    end

    test "the persisted determination carries the basis and authority it used" do
      determination = FmapClassificationService.classify!(
        encounter_identifier: "enc_example_12",
        facility_identifier: "fac_638_example",
        date_of_service: Date.new(2026, 3, 1),
        jurisdiction: "XA",
        facility_authority: @contract_638,
        aian_verified: true,
        evidence_refs: [ AIAN_EVIDENCE ]
      )
      assert_equal "fmap_100_ihs_638", determination.category
      assert_equal "facility_authority", determination.received_through_basis
      assert_equal "contract_638", determination.authority_type
      assert_equal @contract_638.id, determination.facility_authority_id
      assert_equal [ AIAN_EVIDENCE ], determination.evidence_refs
    end

    test "an expansion-adult encounter, in main's eligibility-group vocabulary, is 90 percent" do
      result = classify_638(aian_verified: false, evidence_refs: [], coverage_group: "expansion_adult")
      assert_equal "fmap_90_expansion", result.category
    end

    test "an unrecognised coverage group is rejected, not read as no group" do
      assert_raises(ArgumentError) { classify_638(coverage_group: "expansion") }
    end
  end
end
