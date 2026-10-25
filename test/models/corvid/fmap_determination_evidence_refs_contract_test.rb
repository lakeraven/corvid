# frozen_string_literal: true

require "test_helper"

module Corvid
  # Issue #705 gate round 2: evidence_refs entries are exactly { supports, ref }
  # with caller kinds and opaque token refs (F1, F2, M2).
  class FmapDeterminationEvidenceRefsContractTest < ActiveSupport::TestCase
    TENANT = "tnt_evidence_contract"
    TOKEN = "at_01HK8B7Z9XCQVG3F8N5K0R4MWB"
    VALID_ULID_BODY = "01HK8B7Z9XCQVG3F8N5K0R4MWB"
    VALID_ENTRY = { "supports" => "aian_status", "ref" => TOKEN }.freeze
    BAD_REF = "attestation:tok_example_aian"
    FREE_TEXT_REF = "TEST,PATIENT 001"
    FREE_TEXT_SUPPORTS = "TEST,PATIENT 001"
    CALLER_KINDS = FmapRule::CALLER_EVIDENCE_KINDS

    ENTRY_CONTRACT_ERROR = 'must be { "supports" => kind, "ref" => token } entries'
    SUPPORTS_KIND_ERROR = "may only support #{CALLER_KINDS.join(', ')}"

    setup do
      Corvid::TenantContext.current_tenant_identifier = TENANT
      FmapRuleLoader.load_defaults!
      @uio = FacilityAuthority.create!(
        facility_identifier: "fac_evidence_contract",
        authority_type: "uio",
        effective_on: Date.new(2020, 1, 1)
      )
    end

    test "F1 model new rejects an extra key on an evidence entry" do
      determination = build_hundred_percent_determination(
        evidence_refs: [ VALID_ENTRY.merge("note" => "synthetic-note") ]
      )
      refute determination.valid?
      assert_includes determination.errors[:evidence_refs], ENTRY_CONTRACT_ERROR
    end

    test "F1 model new rejects free-text supports with a token ref" do
      determination = build_hundred_percent_determination(
        evidence_refs: [ { "supports" => FREE_TEXT_SUPPORTS, "ref" => TOKEN } ]
      )
      refute determination.valid?
      assert_includes determination.errors[:evidence_refs], SUPPORTS_KIND_ERROR
    end

    test "F1 model new rejects a missing ref key" do
      determination = build_hundred_percent_determination(
        evidence_refs: [ { "supports" => "aian_status" } ]
      )
      refute determination.valid?
      assert_includes determination.errors[:evidence_refs], ENTRY_CONTRACT_ERROR
    end

    test "F1 model create! rejects malformed evidence_refs" do
      attrs = build_hundred_percent_determination(
        evidence_refs: [ VALID_ENTRY.merge("note" => "synthetic-note") ]
      ).attributes.except("id")
      error = assert_raises(ActiveRecord::RecordInvalid) do
        FmapDetermination.create!(attrs)
      end
      assert_includes error.record.errors[:evidence_refs], ENTRY_CONTRACT_ERROR
    end

    test "F1 model supersede_with! rejects malformed evidence_refs" do
      original = classified_determination
      error = assert_raises(ActiveRecord::RecordInvalid) do
        original.supersede_with!(
          evidence_refs: [ { "supports" => FREE_TEXT_SUPPORTS, "ref" => TOKEN } ]
        )
      end
      assert_includes error.record.errors[:evidence_refs], SUPPORTS_KIND_ERROR
    end

    test "F1 database rejects malformed evidence_refs via update_columns" do
      row = classified_determination
      bad = [ VALID_ENTRY.merge("note" => "synthetic-note") ]
      assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::CheckViolation) do
        FmapDetermination.transaction(requires_new: true) do
          row.update_columns(evidence_refs: bad)
        end
      end
      assert_equal [ VALID_ENTRY ], row.reload.evidence_refs
    end

    test "F1 database rejects malformed evidence_refs via insert_all" do
      assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::CheckViolation) do
        FmapDetermination.transaction(requires_new: true) do
          FmapDetermination.insert_all(
            [ bulk_determination_row(evidence_refs: [ VALID_ENTRY.merge("note" => "synthetic-note") ]) ]
          )
        end
      end
    end

    test "F1 database rejects malformed evidence_refs via upsert_all" do
      row = classified_determination
      bad = [ VALID_ENTRY.merge("note" => "synthetic-note") ]
      assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::CheckViolation) do
        FmapDetermination.transaction(requires_new: true) do
          FmapDetermination.upsert_all(
            [ row.attributes.merge("evidence_refs" => bad, "updated_at" => Time.current) ],
            unique_by: :id
          )
        end
      end
      assert_equal [ VALID_ENTRY ], row.reload.evidence_refs
    end

    test "F2 database rejects evidence_refs stored as a top-level object" do
      row = classified_determination
      assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::CheckViolation) do
        FmapDetermination.transaction(requires_new: true) do
          row.update_columns(evidence_refs: VALID_ENTRY)
        end
      end
      assert_equal [ VALID_ENTRY ], row.reload.evidence_refs
    end

    test "F2 database rejects a nested array of evidence entries" do
      row = classified_determination
      nested = [ [ VALID_ENTRY ] ]
      assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::CheckViolation) do
        FmapDetermination.transaction(requires_new: true) do
          row.update_columns(evidence_refs: nested)
        end
      end
      assert_equal [ VALID_ENTRY ], row.reload.evidence_refs
    end

    test "F2 database rejects a numeric ref via update_columns" do
      row = classified_determination
      bad = [ { "supports" => "aian_status", "ref" => 123_456_789 } ]
      assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::CheckViolation) do
        FmapDetermination.transaction(requires_new: true) do
          row.update_columns(evidence_refs: bad)
        end
      end
      assert_equal [ VALID_ENTRY ], row.reload.evidence_refs
    end

    test "F2 database accepts an empty evidence_refs array" do
      row = classified_determination
      FmapDetermination.transaction(requires_new: true) do
        row.update_columns(evidence_refs: [])
      end
      assert_equal [], row.reload.evidence_refs
    end

    test "M2 non-100-percent determination rejects a non-token ref with the opaque-token validation message" do
      rule = FmapRule.find_by!(rule_key: "us-regular")
      determination = FmapDetermination.new(
        encounter_identifier: "enc_m2_regular",
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "XA",
        determined_at: Time.current,
        category: rule.category,
        rule_key: rule.rule_key,
        fmap_percent: rule.fmap_percent,
        rule_citations: [ rule.statutory_citation ],
        aian_verified: false,
        evidence_refs: [ { "supports" => "aian_status", "ref" => BAD_REF } ]
      )
      refute determination.valid?
      assert_includes determination.errors[:evidence_refs], ENTRY_CONTRACT_ERROR
      determination.errors[:evidence_refs].each do |message|
        refute_includes message, "100 percent"
        refute_match(/lacks .+ for rule/, message)
      end
    end

    test "G3 model rejects a bare Hash for evidence_refs" do
      determination = build_hundred_percent_determination(evidence_refs: VALID_ENTRY)
      refute determination.valid?
      assert_includes determination.errors[:evidence_refs], ENTRY_CONTRACT_ERROR
    end

    test "G3 undetermined determination rejects mixed valid and non-token ref entries" do
      determination = FmapDetermination.new(
        encounter_identifier: "enc_g3_undetermined",
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "XA",
        determined_at: Time.current,
        category: FmapClassificationService::UNDETERMINED,
        determination_reason: FmapClassificationService::NO_RULES_IN_FORCE,
        evidence_refs: [ VALID_ENTRY, { "supports" => "aian_status", "ref" => FREE_TEXT_REF } ]
      )
      refute determination.valid?
      assert_includes determination.errors[:evidence_refs], ENTRY_CONTRACT_ERROR
    end

    test "G3 regular determination rejects mixed valid and non-token ref entries" do
      rule = FmapRule.find_by!(rule_key: "us-regular")
      determination = FmapDetermination.new(
        encounter_identifier: "enc_g3_regular",
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "XA",
        determined_at: Time.current,
        category: rule.category,
        rule_key: rule.rule_key,
        fmap_percent: rule.fmap_percent,
        rule_citations: [ rule.statutory_citation ],
        aian_verified: false,
        evidence_refs: [ VALID_ENTRY, { "supports" => "aian_status", "ref" => FREE_TEXT_REF } ]
      )
      refute determination.valid?
      assert_includes determination.errors[:evidence_refs], ENTRY_CONTRACT_ERROR
    end

    test "P5 non-100 determination rejects a valid token ref with an unsupported supports kind" do
      rule = FmapRule.find_by!(rule_key: "us-regular")
      determination = FmapDetermination.new(
        encounter_identifier: "enc_p5_regular",
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "XA",
        determined_at: Time.current,
        category: rule.category,
        rule_key: rule.rule_key,
        fmap_percent: rule.fmap_percent,
        rule_citations: [ rule.statutory_citation ],
        aian_verified: false,
        evidence_refs: [ VALID_ENTRY, { "supports" => "other", "ref" => TOKEN } ]
      )
      refute determination.valid?
      assert_includes determination.errors[:evidence_refs], SUPPORTS_KIND_ERROR
    end

    test "P2 database CHECK rejects malformed evidence ref anchors on normal schema" do
      row = classified_determination
      malformed_evidence_ref_anchors.each do |bad_ref|
        bad_refs = [ VALID_ENTRY, { "supports" => "aian_status", "ref" => bad_ref } ]
        assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::CheckViolation) do
          FmapDetermination.transaction(requires_new: true) do
            row.update_columns(evidence_refs: bad_refs)
          end
        end
        assert_equal [ VALID_ENTRY ], row.reload.evidence_refs
      end
    end

    test "M2 undetermined determination rejects a non-token ref with the entry contract validation message" do
      determination = FmapDetermination.new(
        encounter_identifier: "enc_m2_undetermined",
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "XA",
        determined_at: Time.current,
        category: FmapClassificationService::UNDETERMINED,
        determination_reason: FmapClassificationService::NO_RULES_IN_FORCE,
        evidence_refs: [ { "supports" => "aian_status", "ref" => BAD_REF } ]
      )
      refute determination.valid?
      assert_includes determination.errors[:evidence_refs], ENTRY_CONTRACT_ERROR
      determination.errors[:evidence_refs].each do |message|
        refute_includes message, "100 percent"
      end
    end

    private

    def malformed_evidence_ref_anchors
      body = VALID_ULID_BODY
      [
        "free text ab_#{body}",
        "abcde_#{body}",
        "AB_#{body}",
        "ab_#{body.downcase}"
      ]
    end

    def build_hundred_percent_determination(**attrs)
      rule = FmapRule.find_by!(rule_key: "us-arpa-9815-uio-100")
      FmapDetermination.new(
        encounter_identifier: "enc_evidence_shape_#{SecureRandom.hex(2)}",
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "XA",
        determined_at: Time.current,
        category: rule.category,
        rule_key: rule.rule_key,
        fmap_percent: rule.fmap_percent,
        rule_citations: [ rule.statutory_citation ],
        aian_verified: true,
        facility_authority: @uio,
        facility_identifier: @uio.facility_identifier,
        authority_type: @uio.authority_type,
        received_through_basis: "facility_authority",
        **attrs
      )
    end

    def classified_determination
      FmapClassificationService.classify!(
        encounter_identifier: "enc_evidence_bulk_#{SecureRandom.hex(3)}",
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "XA",
        facility_authority: @uio,
        aian_verified: true,
        evidence_refs: [ VALID_ENTRY ]
      )
    end

    def bulk_determination_row(evidence_refs:)
      now = Time.current
      {
        tenant_identifier: TENANT,
        encounter_identifier: "enc_bulk_#{SecureRandom.hex(3)}",
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "XA",
        determined_at: now,
        category: FmapClassificationService::UNDETERMINED,
        determination_reason: FmapClassificationService::NO_RULES_IN_FORCE,
        evidence_refs: evidence_refs,
        rule_citations: [],
        missing_evidence: [],
        aian_verified: false,
        created_at: now,
        updated_at: now
      }
    end
  end
end
