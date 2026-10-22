# frozen_string_literal: true

require "test_helper"
require "rake"

module Corvid
  # Pins the audit-row backstops on FmapDetermination (#547 review): a row
  # cites the rule it applied, a 100 percent row rests on the rule's own
  # evidence, and a correction chain has exactly one current row.
  class FmapDeterminationTest < ActiveSupport::TestCase
    AIAN_EVIDENCE = { "supports" => "aian_status", "ref" => "attestation:tok_example_aian" }.freeze

    setup do
      Corvid::TenantContext.current_tenant_identifier = "tnt_example"
      FmapRuleLoader.load_defaults!
      @uio = FacilityAuthority.create!(
        facility_identifier: "fac_uio_example",
        authority_type: "uio",
        effective_on: Date.new(2020, 1, 1)
      )
    end

    def arpa_determination(claim_reference: nil)
      FmapClassificationService.classify!(
        encounter_identifier: "enc_example_20",
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "XA",
        facility_authority: @uio,
        aian_verified: true,
        evidence_refs: [ AIAN_EVIDENCE ],
        claim_reference: claim_reference
      )
    end

    def base_attrs
      {
        encounter_identifier: "enc_example_21",
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "XA",
        determined_at: Time.current
      }
    end

    test "a correction to another rule cites that rule, not the original" do
      original = arpa_determination
      correction = original.supersede_with!(rule_key: "us-regular")

      regular = FmapRule.find_by!(rule_key: "us-regular")
      assert_equal "fmap_regular", correction.category
      assert_equal [ regular.statutory_citation ], correction.rule_citations
      assert_nil correction.fmap_percent
    end

    test "a row whose category disagrees with its rule is invalid" do
      determination = FmapDetermination.new(
        **base_attrs, category: "fmap_regular", rule_key: "us-arpa-9815-uio-100",
        rule_citations: [ "ARPA sec. 9815 (Pub. L. 117-2)" ]
      )
      refute determination.valid?
    end

    test "a row whose citations are not its rule's is invalid" do
      determination = FmapDetermination.new(
        **base_attrs, category: "fmap_regular", rule_key: "us-regular",
        rule_citations: [ "ARPA sec. 9815 (Pub. L. 117-2)" ]
      )
      refute determination.valid?
    end

    test "a statutory category with no rule is invalid" do
      determination = FmapDetermination.new(**base_attrs, category: "fmap_regular")
      refute determination.valid?
    end

    test "a hand-entered 100 percent row without the rule's evidence is invalid" do
      rule = FmapRule.find_by!(rule_key: "us-arpa-9815-uio-100")
      determination = FmapDetermination.new(
        **base_attrs, category: rule.category, rule_key: rule.rule_key,
        fmap_percent: rule.fmap_percent, rule_citations: [ rule.statutory_citation ],
        aian_verified: true, evidence_refs: [ AIAN_EVIDENCE ]
      )
      refute determination.valid?
      assert determination.errors[:evidence_refs].any?
    end

    test "a determination can be superseded only once" do
      original = arpa_determination
      first = original.supersede_with!(rule_key: "us-regular")

      assert_raises(FmapDetermination::AlreadySupersededError) do
        original.supersede_with!(rule_key: "us-regular")
      end
      assert_equal first.id, original.reload.superseded_by_id
      assert_equal 1, FmapDetermination.current.for_encounter("enc_example_20").count
    end

    test "a supersession link cannot be repointed" do
      original = arpa_determination
      original.supersede_with!(rule_key: "us-regular")
      other = arpa_determination

      original.superseded_by_id = other.id
      refute original.valid?
    end

    test "an unknown received-through basis or authority type is a validation error" do
      determination = FmapDetermination.new(
        **base_attrs, category: "undetermined", received_through_basis: "bogus", authority_type: "bogus"
      )
      refute determination.valid?
      assert determination.errors[:received_through_basis].any?
      assert determination.errors[:authority_type].any?
    end

    test "the database rejects an unknown category" do
      original = arpa_determination
      assert_raises(ActiveRecord::StatementInvalid) { original.update_columns(category: "bogus") }
    end

    test "the database rejects an unknown facility authority type" do
      assert_raises(ActiveRecord::StatementInvalid) { @uio.update_columns(authority_type: "bogus") }
    end

    test "the database rejects an unknown FMAP rule category" do
      rule = FmapRule.find_by!(rule_key: "us-regular")
      assert_raises(ActiveRecord::StatementInvalid) { rule.update_columns(category: "bogus") }
    end

    test "a rule's coverage group must be one of main's eligibility groups" do
      rule = FmapRule.find_by!(rule_key: "us-expansion-90")
      assert_equal "expansion_adult", rule.coverage_group
      rule.coverage_group = "expansion"
      refute rule.valid?
    end

    test "rake corvid:fmap:load_rules loads the shipped rule set" do
      FmapRule.delete_all
      Rails.application.load_tasks if Rake::Task.tasks.empty?
      task = Rake::Task["corvid:fmap:load_rules"]
      task.reenable
      assert_output(/\d+/) { task.invoke }
      assert FmapRule.exists?(rule_key: "us-regular")
    end
  end
end
