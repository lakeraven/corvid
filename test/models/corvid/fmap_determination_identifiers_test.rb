# frozen_string_literal: true

require "test_helper"

module Corvid
  # Issue #705: claim_identifier and evidence_refs[].ref must be vault tokens.
  class FmapDeterminationIdentifiersTest < ActiveSupport::TestCase
    AIAN_EVIDENCE = { "supports" => "aian_status", "ref" => "at_01HK8B7Z9XCQVG3F8N5K0R4MWB" }.freeze
    CLAIM_TOKEN = "cl_01HK8B7Z9XCQVG3F8N5K0R4MWC"
    BAD_CLAIM = "clm_example_1"
    BAD_EVIDENCE_REF = "attestation:tok_example_aian"

    setup do
      Corvid::TenantContext.current_tenant_identifier = "tnt_example"
      FmapRuleLoader.load_defaults!
      @uio = FacilityAuthority.create!(
        facility_identifier: "fac_uio_example",
        authority_type: "uio",
        effective_on: Date.new(2020, 1, 1)
      )
    end

    test "classify! accepts claim_identifier and rejects claim_reference" do
      assert_opaque_token_implemented!

      determination = FmapClassificationService.classify!(
        encounter_identifier: "enc_claim_id_1",
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "XA",
        facility_authority: @uio,
        aian_verified: true,
        evidence_refs: [ AIAN_EVIDENCE ],
        claim_identifier: CLAIM_TOKEN
      )
      assert_equal CLAIM_TOKEN, determination.claim_identifier

      assert_raises(ArgumentError, ActiveRecord::UnknownAttributeError) do
        FmapClassificationService.classify!(
          encounter_identifier: "enc_claim_id_2",
          date_of_service: Date.new(2022, 6, 1),
          jurisdiction: "XA",
          facility_authority: @uio,
          aian_verified: true,
          evidence_refs: [ AIAN_EVIDENCE ],
          claim_reference: CLAIM_TOKEN
        )
      end
    end

    test "a non-token claim_identifier makes the model invalid" do
      assert_opaque_token_implemented!
      determination = classified_determination(claim_identifier: BAD_CLAIM)
      refute determination.valid?
      assert determination.errors[:claim_identifier].any?
      determination.errors[:claim_identifier].each do |message|
        refute_includes message, BAD_CLAIM
      end
    end

    test "classify! with a non-token claim_identifier raises and stores nothing" do
      assert_opaque_token_implemented!
      before = FmapDetermination.count
      error = assert_raises(ActiveRecord::RecordInvalid) do
        FmapClassificationService.classify!(
          encounter_identifier: "enc_bad_claim",
          date_of_service: Date.new(2022, 6, 1),
          jurisdiction: "XA",
          facility_authority: @uio,
          aian_verified: true,
          evidence_refs: [ AIAN_EVIDENCE ],
          claim_identifier: BAD_CLAIM
        )
      end
      assert_equal before, FmapDetermination.count
      error.record.errors[:claim_identifier].each do |message|
        refute_includes message, BAD_CLAIM
      end
    end

    test "the database rejects a non-token claim_identifier written with update_columns" do
      assert_opaque_token_implemented!
      row = classified_determination
      assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::CheckViolation) do
        FmapDetermination.transaction(requires_new: true) do
          row.update_columns(claim_identifier: BAD_CLAIM)
        end
      end
      assert_nil row.reload.read_attribute(:claim_identifier)
    end

    test "NULL claim_identifier is allowed at the database" do
      assert_opaque_token_implemented!
      row = classified_determination
      FmapDetermination.transaction(requires_new: true) do
        row.update_columns(claim_identifier: nil)
      end
      assert_nil row.reload.claim_identifier
    end

    test "a claimed row stays immutable when keyed on claim_identifier" do
      assert_opaque_token_implemented!
      determination = classified_determination(claim_identifier: CLAIM_TOKEN)
      determination.category = "non_medicaid"
      assert_raises(ActiveRecord::RecordInvalid) { determination.save! }

      determination.reload
      determination.claim_identifier = "cl_01HK8B7Z9XCQVG3F8N5K0R4MWD"
      refute determination.valid?
      determination.errors.full_messages.each do |message|
        refute_includes message, CLAIM_TOKEN
        refute_includes message, "cl_01HK8B7Z9XCQVG3F8N5K0R4MWD"
      end
    end

    test "classify rejects a non-token evidence ref before persisting" do
      assert_opaque_token_implemented!
      before = FmapDetermination.count
      error = assert_raises(ArgumentError) do
        FmapClassificationService.classify!(
          encounter_identifier: "enc_bad_evidence",
          date_of_service: Date.new(2022, 6, 1),
          jurisdiction: "XA",
          facility_authority: @uio,
          aian_verified: true,
          evidence_refs: [ { "supports" => "aian_status", "ref" => BAD_EVIDENCE_REF } ]
        )
      end
      assert_equal before, FmapDetermination.count
      refute_includes error.message, BAD_EVIDENCE_REF
    end

    test "classify! rejects a non-token evidence ref before persisting" do
      assert_opaque_token_implemented!
      before = FmapDetermination.count
      error = assert_raises(ArgumentError) do
        FmapClassificationService.classify!(
          encounter_identifier: "enc_bad_evidence_bang",
          date_of_service: Date.new(2022, 6, 1),
          jurisdiction: "XA",
          facility_authority: @uio,
          aian_verified: true,
          evidence_refs: [ { "supports" => "aian_status", "ref" => BAD_EVIDENCE_REF } ]
        )
      end
      assert_equal before, FmapDetermination.count
      refute_includes error.message, BAD_EVIDENCE_REF
    end

    test "the model is invalid when any evidence ref is not a token" do
      assert_opaque_token_implemented!
      rule = FmapRule.find_by!(rule_key: "us-arpa-9815-uio-100")
      determination = FmapDetermination.new(
        encounter_identifier: "enc_evidence_invalid",
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "XA",
        determined_at: Time.current,
        category: rule.category,
        rule_key: rule.rule_key,
        fmap_percent: rule.fmap_percent,
        rule_citations: [ rule.statutory_citation ],
        aian_verified: true,
        evidence_refs: [ AIAN_EVIDENCE, { "supports" => "aian_status", "ref" => BAD_EVIDENCE_REF } ]
      )
      refute determination.valid?
      assert determination.errors[:evidence_refs].any?
    end

    test "the database rejects evidence_refs containing a non-token ref via update_columns" do
      assert_opaque_token_implemented!
      row = classified_determination
      bad_refs = [ AIAN_EVIDENCE, { "supports" => "aian_status", "ref" => BAD_EVIDENCE_REF } ]
      assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::CheckViolation) do
        FmapDetermination.transaction(requires_new: true) do
          row.update_columns(evidence_refs: bad_refs)
        end
      end
      assert_equal [ AIAN_EVIDENCE ], row.reload.evidence_refs
    end

    private

    def assert_opaque_token_implemented!
      assert defined?(OpaqueToken), "Corvid::OpaqueToken must be implemented"
    end

    def classified_determination(claim_identifier: nil)
      FmapClassificationService.classify!(
        encounter_identifier: "enc_id_#{SecureRandom.hex(3)}",
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "XA",
        facility_authority: @uio,
        aian_verified: true,
        evidence_refs: [ AIAN_EVIDENCE ],
        claim_identifier: claim_identifier
      )
    end
  end
end
