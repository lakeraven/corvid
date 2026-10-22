# frozen_string_literal: true

require "test_helper"

module Corvid
  # The determination's own backstop (#547 panel): a 100 percent row
  # resting on a facility authority must rest on its own facility's
  # authority, however it was written.
  class FmapDeterminationFacilityTest < ActiveSupport::TestCase
    AIAN_EVIDENCE = { "supports" => "aian_status", "ref" => "attestation:tok_example_aian" }.freeze

    setup do
      Corvid::TenantContext.current_tenant_identifier = "tnt_example"
      FmapRuleLoader.load_defaults!
      @contract_638 = FacilityAuthority.create!(
        facility_identifier: "fac_638_example",
        authority_type: "contract_638",
        effective_on: Date.new(2020, 1, 1)
      )
    end

    def hundred_percent_attrs(facility_identifier:)
      rule = FmapRule.find_by!(rule_key: "us-ihs-638-100")
      {
        encounter_identifier: "enc_example_20",
        facility_identifier: facility_identifier,
        date_of_service: Date.new(2026, 3, 1),
        jurisdiction: "XA",
        category: rule.category,
        fmap_percent: rule.fmap_percent,
        rule_key: rule.rule_key,
        rule_citations: [ rule.statutory_citation ],
        evidence_refs: [ AIAN_EVIDENCE ],
        aian_verified: true,
        received_through_basis: "facility_authority",
        facility_authority_id: @contract_638.id,
        authority_type: "contract_638",
        determined_at: Time.current
      }
    end

    test "a 100 percent row backed by its own facility's authority is valid" do
      assert FmapDetermination.new(hundred_percent_attrs(facility_identifier: "fac_638_example")).valid?
    end

    test "a 100 percent row cannot rest on another facility's authority" do
      determination = FmapDetermination.new(hundred_percent_attrs(facility_identifier: "fac_plain_example"))
      refute determination.valid?
      assert_includes determination.errors[:evidence_refs].join, "received_through_evidence"
    end

    test "an unrecognised coverage group or reason is rejected by the model and the database" do
      attrs = hundred_percent_attrs(facility_identifier: "fac_638_example")
      refute FmapDetermination.new(attrs.merge(coverage_group: "bogus")).valid?
      refute FmapDetermination.new(attrs.merge(determination_reason: "bogus")).valid?
      assert FmapDetermination.new(attrs.merge(coverage_group: "unknown")).valid?

      row = FmapDetermination.create!(attrs)
      assert_raises(ActiveRecord::StatementInvalid) { row.update_columns(coverage_group: "bogus") }
      assert_raises(ActiveRecord::StatementInvalid) { row.update_columns(determination_reason: "bogus") }
    end

    test "any row naming an authority must name its own facility's, in its own tenant" do
      regular = FmapRule.find_by!(rule_key: "us-regular")
      attrs = {
        encounter_identifier: "enc_example_22", facility_identifier: "fac_plain_example",
        date_of_service: Date.new(2026, 3, 1), jurisdiction: "XA",
        category: regular.category, rule_key: regular.rule_key,
        rule_citations: [ regular.statutory_citation ], determined_at: Time.current
      }
      refute FmapDetermination.new(attrs.merge(facility_authority_id: @contract_638.id)).valid?

      Corvid::TenantContext.current_tenant_identifier = "tnt_other_example"
      other = FacilityAuthority.create!(facility_identifier: "fac_plain_example", authority_type: "fqhc",
                                        effective_on: Date.new(2020, 1, 1))
      Corvid::TenantContext.current_tenant_identifier = "tnt_example"
      refute FmapDetermination.new(attrs.merge(facility_authority_id: other.id)).valid?
    end

    test "a row naming an authority records that authority's type" do
      regular = FmapRule.find_by!(rule_key: "us-regular")
      determination = FmapDetermination.new(
        encounter_identifier: "enc_example_23", facility_identifier: "fac_638_example",
        date_of_service: Date.new(2026, 3, 1), jurisdiction: "XA",
        category: regular.category, rule_key: regular.rule_key,
        rule_citations: [ regular.statutory_citation ], determined_at: Time.current,
        facility_authority_id: @contract_638.id, authority_type: "fqhc"
      )
      refute determination.valid?
      assert determination.errors[:authority_type].any?
    end

    test "moving a 100 percent row to another facility re-runs the authority check" do
      row = FmapDetermination.create!(hundred_percent_attrs(facility_identifier: "fac_638_example"))
      refute row.update(facility_identifier: "fac_plain_example")
    end

    test "a correction is appended in the row's own tenant or not at all" do
      original = FmapClassificationService.classify!(
        encounter_identifier: "enc_example_24", facility_identifier: "fac_plain_example",
        date_of_service: Date.new(2026, 3, 1), jurisdiction: "XA"
      )
      Corvid::TenantContext.current_tenant_identifier = "tnt_other_example"
      assert_raises(ArgumentError) { original.supersede_with!(rule_key: "us-regular") }
      assert_equal 0, FmapDetermination.unscoped.where(tenant_identifier: "tnt_other_example").count
    ensure
      Corvid::TenantContext.current_tenant_identifier = "tnt_example"
    end

    test "a correction cannot change whose encounter it is" do
      original = FmapClassificationService.classify!(
        encounter_identifier: "enc_example_25", person_identifier: "pt_test_001",
        facility_identifier: "fac_plain_example", date_of_service: Date.new(2026, 3, 1), jurisdiction: "XA"
      )
      assert_raises(ArgumentError) { original.supersede_with!(rule_key: "us-regular", encounter_identifier: "enc_other") }
      assert_raises(ArgumentError) { original.supersede_with!(rule_key: "us-regular", person_identifier: "pt_test_002") }
      assert_raises(ArgumentError) { original.supersede_with!(rule_key: "us-regular", tenant_identifier: "tnt_other") }
      assert_nil original.reload.superseded_by_id
    end

    test "an undetermined row carries no percent" do
      row = FmapDetermination.new(
        encounter_identifier: "enc_example_26", date_of_service: Date.new(2026, 3, 1), jurisdiction: "XA",
        category: FmapClassificationService::UNDETERMINED, fmap_percent: 100, determined_at: Time.current
      )
      refute row.valid?
      assert row.errors[:fmap_percent].any?
    end

    test "a correction cannot move a row onto another facility's authority" do
      original = FmapClassificationService.classify!(
        encounter_identifier: "enc_example_21",
        facility_identifier: "fac_plain_example",
        date_of_service: Date.new(2026, 3, 1),
        jurisdiction: "XA"
      )
      assert_equal "fmap_regular", original.category

      assert_raises(ActiveRecord::RecordInvalid) do
        original.supersede_with!(
          rule_key: "us-ihs-638-100",
          aian_verified: true,
          evidence_refs: [ AIAN_EVIDENCE ],
          received_through_basis: "facility_authority",
          facility_authority_id: @contract_638.id,
          authority_type: "contract_638"
        )
      end
      assert_nil original.reload.superseded_by_id
    end
  end
end
