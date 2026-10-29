# frozen_string_literal: true

require "test_helper"

module Corvid
  # Issue #680: persisted expansion-tier rows must rest on a configured
  # expansion state, whether written by classification or correction.
  class FmapDeterminationExpansionStateTest < ActiveSupport::TestCase
    DOS = Date.new(2026, 3, 1)

    setup do
      Corvid::TenantContext.current_tenant_identifier = "tnt_test"
      FmapRuleLoader.load_defaults!
    end

    test "supersede_with expansion rule in configured non-expansion XB is refused" do
      original = FmapClassificationService.classify!(
        encounter_identifier: "enc_test_680_supersede_xb",
        date_of_service: DOS,
        jurisdiction: "XB",
        coverage_group: "expansion_adult",
        aian_verified: false
      )
      assert_equal FmapClassificationService::UNDETERMINED, original.category

      assert_raises(ActiveRecord::RecordInvalid) do
        original.supersede_with!(rule_key: "us-expansion-90")
      end

      original.reload
      assert_nil original.superseded_by_id
      assert_equal 1, FmapDetermination.current.for_encounter("enc_test_680_supersede_xb").count
    end

    test "hand-entered expansion tier in unregistered XC is invalid" do
      determination = FmapDetermination.new(**expansion_attrs(jurisdiction: "XC"))

      assert_raises(ActiveRecord::RecordInvalid) { determination.save! }
    end

    test "hand-entered expansion tier in expanded XA is valid" do
      determination = FmapDetermination.new(**expansion_attrs(jurisdiction: "XA"))
      determination.save!

      assert determination.persisted?
    end

    test "hand-entered expansion-scoped fmap_regular in non-expansion XB is invalid" do
      xb_rule = FmapRule.create!(
        rule_key: "xb-test-expansion-scoped-model",
        jurisdiction: "XB",
        category: "fmap_regular",
        fmap_percent: 90.0,
        coverage_group: "expansion_adult",
        statutory_citation: "Synthetic test citation for issue 680 model gate round 2",
        effective_on: Date.new(2020, 1, 1)
      )

      xb_determination = FmapDetermination.new(
        encounter_identifier: "enc_test_680_scoped_model_xb",
        date_of_service: DOS,
        jurisdiction: "XB",
        determined_at: Time.current,
        coverage_group: "expansion_adult",
        category: "fmap_regular",
        fmap_percent: 90.0,
        rule_key: xb_rule.rule_key,
        rule_citations: [ xb_rule.statutory_citation ]
      )

      assert_raises(ActiveRecord::RecordInvalid) { xb_determination.save! }
      assert xb_determination.errors[:jurisdiction].present?

      xa_rule = FmapRule.create!(
        rule_key: "xa-test-expansion-scoped-model",
        jurisdiction: "XA",
        category: "fmap_regular",
        fmap_percent: 90.0,
        coverage_group: "expansion_adult",
        statutory_citation: "Synthetic test citation for issue 680 model gate round 2 control",
        effective_on: Date.new(2020, 1, 1)
      )

      xa_determination = FmapDetermination.create!(
        encounter_identifier: "enc_test_680_scoped_model_xa",
        date_of_service: DOS,
        jurisdiction: "XA",
        determined_at: Time.current,
        coverage_group: "expansion_adult",
        category: "fmap_regular",
        fmap_percent: 90.0,
        rule_key: xa_rule.rule_key,
        rule_citations: [ xa_rule.statutory_citation ]
      )

      assert xa_determination.persisted?
    end

    private

    def expansion_attrs(jurisdiction:)
      rule = FmapRule.find_by!(rule_key: "us-expansion-90")
      {
        encounter_identifier: "enc_test_680_expansion_model_#{jurisdiction.downcase}",
        date_of_service: DOS,
        jurisdiction: jurisdiction,
        determined_at: Time.current,
        coverage_group: "expansion_adult",
        category: rule.category,
        rule_key: rule.rule_key,
        fmap_percent: rule.fmap_percent,
        rule_citations: [ rule.statutory_citation ]
      }
    end
  end
end
