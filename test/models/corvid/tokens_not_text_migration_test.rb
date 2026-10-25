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
    REVIEWER_TOKEN = "rv_01HK8B7Z9XCQVG3F8N5K0R4MWD"
    MIGRATION_ABORT_PREFIX = "refusing to replace free text with tokens: "
    BAD_REVIEWER = "reviewer-synthetic-mig"

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
      refute_includes fmap_columns, "claim_reference"
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

      before_claim = down_determination_claim_reference(determination_id)
      error = assert_raises(StandardError) { migrate_tokens!(:up) }
      refute_includes error.message, bad_claim
      assert_match(/\d+/, error.message)

      assert_equal bad_claim, down_determination_claim_reference(determination_id)
      refute_includes fmap_columns, "claim_identifier"
      assert_equal before_claim, down_determination_claim_reference(determination_id)
    ensure
      cleanup_determination!(determination_id)
      ensure_up!
    end

    test "F1 up aborts when evidence_refs have free-text supports with a token ref" do
      determination_id = nil
      with_migration_down do
        determination_id = insert_down_state_determination!
        bad_refs = [ { "supports" => "TEST,PATIENT 001", "ref" => AIAN_EVIDENCE.fetch("ref") } ]
        update_down_determination_evidence_refs!(determination_id, bad_refs)
      end

      error = assert_raises(StandardError) { migrate_tokens!(:up) }
      refute_includes error.message, "TEST,PATIENT 001"
      assert_match(/1 row\(s\) with a non-token evidence ref/, error.message)

      migrate_tokens!(:down)
      refs = down_determination_evidence_refs(determination_id)
      assert_equal "TEST,PATIENT 001", refs.first["supports"]
    ensure
      cleanup_determination!(determination_id)
      ensure_up!
    end

    test "F1 up aborts when evidence_refs carry an extra key with counts only" do
      determination_id = nil
      with_migration_down do
        determination_id = insert_down_state_determination!
        bad_refs = [ AIAN_EVIDENCE.merge("note" => "synthetic-note") ]
        update_down_determination_evidence_refs!(determination_id, bad_refs)
      end

      error = assert_raises(StandardError) { migrate_tokens!(:up) }
      refute_includes error.message, "synthetic-note"
      assert_match(/1 row\(s\) with a non-token evidence ref/, error.message)
    ensure
      cleanup_determination!(determination_id)
      ensure_up!
    end

    test "M5 up abort message states exact non-token claim_reference counts" do
      determination_ids = []
      with_migration_down do
        2.times do |index|
          determination_ids << insert_down_state_determination!(claim_reference: "clm_mig_bad_#{index}")
        end
      end

      error = assert_raises(StandardError) { migrate_tokens!(:up) }
      assert_equal(
        "#{MIGRATION_ABORT_PREFIX}2 non-token claim_reference row(s), 0 row(s) with a non-token evidence ref",
        error.message
      )
    ensure
      determination_ids.each { |id| cleanup_determination!(id) }
      ensure_up!
    end

    test "M6 up drops unmapped current_activity variants without mapping them" do
      [
        "submitted via fhir pas",
        "Submitted via FHIR PAS ",
        "FHIR something"
      ].each do |activity_text|
        referral_id = nil
        with_migration_down do
          referral_id = insert_down_state_referral!(current_activity: activity_text)
        end

        migrate_tokens!(:up)
        row = PrcReferral.find(referral_id)
        assert_nil row.current_activity_code, "expected NULL code for #{activity_text.inspect}"
        assert_nil row.reviewer_identifier
      ensure
        cleanup_referral!(referral_id)
        ensure_up!
      end
    end

    test "M12 down restores exact display text for mapped activity codes" do
      submitted_id = insert_up_state_referral!(current_activity_code: "submitted_via_fhir_pas", reviewer_identifier: nil)
      assigned_id = insert_up_state_referral!(
        current_activity_code: "assigned_to_reviewer",
        reviewer_identifier: REVIEWER_TOKEN
      )

      migrate_tokens!(:down)

      assert_equal SUBMITTED_VIA_FHIR_TEXT, down_referral_current_activity(submitted_id)
      assert_equal "Assigned to reviewer", down_referral_current_activity(assigned_id)
    ensure
      cleanup_referral!(submitted_id)
      cleanup_referral!(assigned_id)
      ensure_up!
    end

    test "up aborts when evidence_refs contain a non-token ref with counts only" do
      determination_id = nil
      bad_ref = "attestation:tok_example_aian"
      with_migration_down do
        determination_id = insert_down_state_determination!
        bad_refs = [ AIAN_EVIDENCE, { "supports" => "aian_status", "ref" => bad_ref } ]
        update_down_determination_evidence_refs!(determination_id, bad_refs)
      end

      error = assert_raises(StandardError) { migrate_tokens!(:up) }
      refute_includes error.message, bad_ref
      assert_match(/\d+/, error.message)

      migrate_tokens!(:down)
      refs = down_determination_evidence_refs(determination_id)
      assert_equal bad_ref, refs.last["ref"]
    ensure
      cleanup_determination!(determination_id)
      ensure_up!
    end

    test "G4 migration CHECK constraints reject malformed token columns after down then up" do
      determination_id = nil
      referral_id = nil
      migrate_tokens!(:down)
      migrate_tokens!(:up)

      determination_id = insert_up_state_determination!
      row = FmapDetermination.find(determination_id)
      token = AIAN_EVIDENCE.fetch("ref")

      [
        [ 5 ],
        [ nil ],
        [ "x" ],
        [ [] ],
        AIAN_EVIDENCE,
        [ AIAN_EVIDENCE.merge("note" => "x") ]
      ].each do |bad_evidence|
        assert_check_violation do
          row.update_columns(evidence_refs: bad_evidence)
        end
        assert_equal [], row.reload.evidence_refs
      end

      claim_ulid = CLAIM_TOKEN.split("_", 2).last
      assert_check_violation do
        row.update_columns(claim_identifier: "x#{claim_ulid}")
      end
      assert_nil row.reload.claim_identifier

      assert_check_violation do
        row.update_columns(claim_identifier: "#{CLAIM_TOKEN}\n")
      end
      assert_nil row.reload.claim_identifier

      referral_id = insert_up_state_referral!(
        current_activity_code: "assigned_to_reviewer",
        reviewer_identifier: REVIEWER_TOKEN
      )
      referral = PrcReferral.find(referral_id)

      assert_check_violation do
        referral.update_columns(reviewer_identifier: BAD_REVIEWER)
      end
      assert_equal REVIEWER_TOKEN, referral.reload.reviewer_identifier

      assert_check_violation do
        referral.update_columns(reviewer_identifier: nil)
      end
      assert_equal REVIEWER_TOKEN, referral.reload.reviewer_identifier
    ensure
      cleanup_determination!(determination_id)
      cleanup_referral!(referral_id)
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
      db_connection.columns(:corvid_fmap_determinations).map(&:name)
    end

    def prc_columns
      db_connection.columns(:corvid_prc_referrals).map(&:name)
    end

    def db_connection
      ActiveRecord::Base.connection
    end

    def quote(value)
      db_connection.quote(value)
    end

    def quote_json(value)
      "#{quote(value.to_json)}::jsonb"
    end

    def quote_time(time)
      quote(time)
    end

    def assert_check_violation
      assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::CheckViolation) do
        FmapDetermination.transaction(requires_new: true) do
          yield
        end
      end
    end

    def insert_up_state_determination!
      now = Time.current
      FmapDetermination.create!(
        tenant_identifier: TENANT,
        encounter_identifier: "enc_mig_up_#{SecureRandom.hex(3)}",
        date_of_service: Date.new(2022, 6, 1),
        jurisdiction: "XA",
        determined_at: now,
        category: FmapClassificationService::UNDETERMINED,
        determination_reason: FmapClassificationService::NO_RULES_IN_FORCE,
        evidence_refs: []
      ).id
    end

    def insert_up_state_referral!(current_activity_code:, reviewer_identifier:)
      kase = Case.create!(patient_identifier: "pt_mig_up_#{SecureRandom.hex(2)}", facility_identifier: FACILITY)
      referral = PrcReferral.create!(
        case: kase,
        referral_identifier: "rf_mig_up_#{SecureRandom.hex(3)}",
        facility_identifier: FACILITY,
        current_activity_code: current_activity_code,
        reviewer_identifier: reviewer_identifier
      )
      referral.id
    end

    def insert_down_state_referral!(current_activity:)
      kase = Case.create!(patient_identifier: "pt_mig_#{SecureRandom.hex(2)}", facility_identifier: FACILITY)
      db_connection.select_value(<<~SQL).to_i
        INSERT INTO corvid_prc_referrals (
          tenant_identifier, facility_identifier, case_id, referral_identifier,
          status, currency_iso, created_at, updated_at, current_activity
        ) VALUES (
          #{quote(TENANT)}, #{quote(FACILITY)}, #{kase.id}, #{quote("rf_mig_#{SecureRandom.hex(3)}")},
          'draft', 'USD', #{quote_time(Time.current)}, #{quote_time(Time.current)}, #{quote(current_activity)}
        ) RETURNING id
      SQL
    end

    def insert_down_state_determination!(claim_reference: nil)
      now = Time.current
      claim_sql = claim_reference.nil? ? "NULL" : quote(claim_reference)
      db_connection.select_value(<<~SQL).to_i
        INSERT INTO corvid_fmap_determinations (
          tenant_identifier, encounter_identifier, date_of_service, jurisdiction,
          determined_at, category, determination_reason, evidence_refs,
          rule_citations, missing_evidence, aian_verified, created_at, updated_at,
          claim_reference
        ) VALUES (
          #{quote(TENANT)}, #{quote("enc_mig_#{SecureRandom.hex(3)}")}, #{quote(Date.new(2022, 6, 1))},
          #{quote("XA")}, #{quote_time(now)}, #{quote(FmapClassificationService::UNDETERMINED)},
          #{quote(FmapClassificationService::NO_RULES_IN_FORCE)}, '[]'::jsonb,
          '[]'::jsonb, '[]'::jsonb, false, #{quote_time(now)}, #{quote_time(now)},
          #{claim_sql}
        ) RETURNING id
      SQL
    end

    def update_down_determination_evidence_refs!(determination_id, evidence_refs)
      db_connection.exec_update(<<~SQL)
        UPDATE corvid_fmap_determinations
        SET evidence_refs = #{quote_json(evidence_refs)}
        WHERE id = #{determination_id.to_i}
      SQL
    end

    def down_determination_claim_reference(determination_id)
      db_connection.select_value(<<~SQL)
        SELECT claim_reference FROM corvid_fmap_determinations WHERE id = #{determination_id.to_i}
      SQL
    end

    def down_determination_evidence_refs(determination_id)
      JSON.parse(
        db_connection.select_value(<<~SQL)
          SELECT evidence_refs::text FROM corvid_fmap_determinations WHERE id = #{determination_id.to_i}
        SQL
      )
    end

    def down_referral_current_activity(referral_id)
      db_connection.select_value(<<~SQL)
        SELECT current_activity FROM corvid_prc_referrals WHERE id = #{referral_id.to_i}
      SQL
    end

    def cleanup_referral!(referral_id)
      return if referral_id.nil?

      case_id = db_connection.select_value(
        "SELECT case_id FROM corvid_prc_referrals WHERE id = #{referral_id.to_i}"
      )
      return if case_id.nil?

      db_connection.exec_delete("DELETE FROM corvid_prc_referrals WHERE id = #{referral_id.to_i}")
      db_connection.exec_delete("DELETE FROM corvid_cases WHERE id = #{case_id.to_i}")
    end

    def cleanup_determination!(determination_id)
      return if determination_id.nil?

      db_connection.exec_delete(
        "DELETE FROM corvid_fmap_determinations WHERE id = #{determination_id.to_i}"
      )
    end
  end
end
