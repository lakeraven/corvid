# frozen_string_literal: true

require "test_helper"

module Corvid
  class TokensNotTextMigrationTest < ActiveSupport::TestCase
    TENANT = "tnt_tokens_mig"
    FACILITY = "fac_tokens_mig"
    AIAN_EVIDENCE = { "supports" => "aian_status", "ref" => "at_01HK8B7Z9XCQVG3F8N5K0R4MWB" }.freeze
    CLAIM_TOKEN = "cl_01HK8B7Z9XCQVG3F8N5K0R4MWC"
    SUBMITTED_VIA_FHIR_TEXT = "Submitted via FHIR PAS"
    ASSIGNED_REVIEWER_TEXT = "Assigned to reviewer 12345"

    setup do
      Corvid::TenantContext.current_tenant_identifier = TENANT
      FmapRuleLoader.load_defaults!
      @migration_path = require_tokens_migration!
    end

    test "down then up round-trips claim and activity columns" do
      with_migration_down do
        assert_includes fmap_columns, "claim_reference"
        refute_includes fmap_columns, "claim_identifier"
        assert_includes prc_columns, "current_activity"
        refute_includes prc_columns, "current_activity_code"
        refute_includes prc_columns, "reviewer_identifier"
      end

      migrate_tokens!(:up)

      assert_includes fmap_columns, "claim_identifier"
      refute_includes fmap_columns, "claim_reference"
      assert_includes prc_columns, "current_activity_code"
      assert_includes prc_columns, "reviewer_identifier"
      refute_includes prc_columns, "current_activity"
    end

    test "up maps Submitted via FHIR PAS text to submitted_via_fhir_pas" do
      referral_id = nil
      with_migration_down do
        referral_id = insert_down_state_referral!(current_activity: SUBMITTED_VIA_FHIR_TEXT)
      end

      migrate_tokens!(:up)
      row = PrcReferral.find(referral_id)
      assert_equal "submitted_via_fhir_pas", row.current_activity_code
      assert_nil row.reviewer_identifier
    ensure
      cleanup_referral!(referral_id)
      ensure_up!
    end

    test "up drops unmapped current_activity text instead of parsing reviewer_identifier" do
      referral_id = nil
      with_migration_down do
        referral_id = insert_down_state_referral!(current_activity: ASSIGNED_REVIEWER_TEXT)
      end

      migrate_tokens!(:up)
      row = PrcReferral.find(referral_id)
      assert_nil row.current_activity_code
      assert_nil row.reviewer_identifier
    ensure
      cleanup_referral!(referral_id)
      ensure_up!
    end

    test "up renames a token-shaped claim_reference to claim_identifier" do
      determination_id = nil
      with_migration_down do
        determination_id = insert_down_state_determination!(claim_reference: CLAIM_TOKEN)
      end

      migrate_tokens!(:up)
      row = FmapDetermination.find(determination_id)
      assert_equal CLAIM_TOKEN, row.claim_identifier
      assert_nil row.read_attribute(:claim_reference)
    ensure
      cleanup_determination!(determination_id)
      ensure_up!
    end

    test "up aborts on a non-token claim_reference with counts only and changes nothing" do
      determination_id = nil
      bad_claim = "clm_example_1"
      with_migration_down do
        determination_id = insert_down_state_determination!(claim_reference: bad_claim)
      end

      before_claim = FmapDetermination.find(determination_id).read_attribute(:claim_reference)
      error = assert_raises(StandardError) { migrate_tokens!(:up) }
      refute_includes error.message, bad_claim
      assert_match(/\d+/, error.message)

      with_migration_down do
        assert_equal bad_claim, FmapDetermination.find(determination_id).read_attribute(:claim_reference)
        refute_includes fmap_columns, "claim_identifier"
      end
      assert_equal before_claim, FmapDetermination.find(determination_id).read_attribute(:claim_reference)
    ensure
      cleanup_determination!(determination_id)
      ensure_up!
    end

    test "up aborts when evidence_refs contain a non-token ref with counts only" do
      determination_id = nil
      bad_ref = "attestation:tok_example_aian"
      with_migration_down do
        determination_id = insert_down_state_determination!(
          claim_reference: nil,
          evidence_refs: [ AIAN_EVIDENCE, { "supports" => "aian_status", "ref" => bad_ref } ]
        )
      end

      error = assert_raises(StandardError) { migrate_tokens!(:up) }
      refute_includes error.message, bad_ref
      assert_match(/\d+/, error.message)

      with_migration_down do
        refs = FmapDetermination.find(determination_id).evidence_refs
        assert_equal bad_ref, refs.last["ref"]
      end
    ensure
      cleanup_determination!(determination_id)
      ensure_up!
    end

    private

    def require_tokens_migration!
      paths = Dir[
        Rails.root.join("db/migrate/*_replace_free_text_with_tokens.rb").to_s,
        Corvid::Engine.root.join("db/migrate/*_replace_free_text_with_tokens.rb").to_s
      ]
      flunk "expected migration file matching *_replace_free_text_with_tokens.rb" if paths.empty?

      path = paths.first
      require path unless defined?(ReplaceFreeTextWithTokens)
      path
    end

    def migrate_tokens!(direction)
      ActiveRecord::Migration.suppress_messages do
        ReplaceFreeTextWithTokens.new.migrate(direction)
      end
      FmapDetermination.reset_column_information
      PrcReferral.reset_column_information
    end

    def with_migration_down
      migrate_tokens!(:down)
      yield
    end

    def ensure_up!
      migrate_tokens!(:up) unless fmap_columns.include?("claim_identifier")
    end

    def fmap_columns
      FmapDetermination.connection.columns(:corvid_fmap_determinations).map(&:name)
    end

    def prc_columns
      PrcReferral.connection.columns(:corvid_prc_referrals).map(&:name)
    end

    def insert_down_state_referral!(current_activity:)
      kase = Case.create!(patient_identifier: "pt_mig_#{SecureRandom.hex(2)}", facility_identifier: FACILITY)
      referral = PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_mig_#{SecureRandom.hex(3)}",
        facility_identifier: FACILITY
      )
      referral.update_columns(current_activity: current_activity)
      referral.id
    end

    def insert_down_state_determination!(claim_reference:, evidence_refs: [ AIAN_EVIDENCE ])
      rule = FmapRule.find_by!(rule_key: "us-arpa-9815-uio-100")
      row = FmapDetermination.create!(
        tenant_identifier: TENANT,
        encounter_identifier: "enc_mig_#{SecureRandom.hex(3)}",
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "XA",
        determined_at: Time.current,
        category: rule.category,
        rule_key: rule.rule_key,
        fmap_percent: rule.fmap_percent,
        rule_citations: [ rule.statutory_citation ],
        aian_verified: true,
        evidence_refs: evidence_refs
      )
      row.update_columns(claim_reference: claim_reference)
      row.id
    end

    def cleanup_referral!(referral_id)
      return if referral_id.nil?

      referral = PrcReferral.unscoped.find_by(id: referral_id)
      return if referral.nil?

      Case.unscoped.where(id: referral.case_id).delete_all
      referral.delete
    end

    def cleanup_determination!(determination_id)
      return if determination_id.nil?

      FmapDetermination.unscoped.where(id: determination_id).delete_all
    end
  end
end
