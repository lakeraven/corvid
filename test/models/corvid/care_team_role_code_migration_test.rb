# frozen_string_literal: true

require "test_helper"

module Corvid
  class CareTeamRoleCodeMigrationTest < ActiveSupport::TestCase
    TENANT = "tnt_ctm_role_mig"
    FACILITY = "fac_ctm_role_mig"
    MIGRATION_ABORT_PREFIX = "refusing to replace care team member role with role_code: "

    setup do
      Corvid::TenantContext.current_tenant_identifier = TENANT
      @migration_path = require_role_code_migration!
    end

    teardown do
      clear_migration_schema_caches!
      ensure_up! if defined?(ReplaceCareTeamMemberRoleWithRoleCode)
    end

    test "down then up round-trips role and role_code columns" do
      member_id = nil
      with_migration_down do
        refute_includes ctm_columns, "role_code"
        assert_includes ctm_columns, "role"
        member_id = insert_down_state_member!(role: "Consultant")
      end

      migrate_role_code!(:up)
      assert_includes ctm_columns, "role_code"
      refute_includes ctm_columns, "role"
      assert_equal "consultant", CareTeamMember.find(member_id).role_code

      migrate_role_code!(:down)
      assert_includes ctm_columns, "role"
      refute_includes ctm_columns, "role_code"
      assert_equal "Consultant", down_member_role(member_id)

      migrate_role_code!(:up)
      assert_equal "consultant", CareTeamMember.find(member_id).role_code
    ensure
      cleanup_member!(member_id)
    end

    {
      "PCP" => "primary_care_provider",
      "Primary Care Provider" => "primary_care_provider",
      "primary care physician" => "primary_care_provider",
      "Care Manager" => "care_manager",
      "Case Manager" => "care_manager",
      "Consultant" => "consultant",
      "Other" => "other"
    }.each do |legacy_text, expected_code|
      test "up maps #{legacy_text.inspect} to #{expected_code}" do
        member_id = nil
        with_migration_down do
          member_id = insert_down_state_member!(role: legacy_text)
        end

        migrate_role_code!(:up)
        assert_equal expected_code, CareTeamMember.find(member_id).role_code
      ensure
        cleanup_member!(member_id)
        ensure_up!
      end
    end

    test "up aborts on unmapped non-null role with counts only" do
      member_id = nil
      with_migration_down do
        member_id = insert_down_state_member!(role: "admin")
      end

      error = assert_raises(StandardError) { migrate_role_code!(:up) }
      refute_includes error.message, "admin"
      assert_equal "#{MIGRATION_ABORT_PREFIX}1 row(s) with unmappable role", error.message
      assert_equal "admin", down_member_role(member_id)
    ensure
      cleanup_member!(member_id)
      ensure_up!
    end

    test "up aborts on NULL role with counts only" do
      member_id = nil
      with_migration_down do
        member_id = insert_down_state_member!(role: nil)
      end

      error = assert_raises(StandardError) { migrate_role_code!(:up) }
      assert_equal "#{MIGRATION_ABORT_PREFIX}1 row(s) with unmappable role", error.message
      assert_nil down_member_role(member_id)
    ensure
      cleanup_member!(member_id)
      ensure_up!
    end

    test "up aborts on blank role with counts only" do
      member_id = nil
      with_migration_down do
        member_id = insert_down_state_member!(role: "   ")
      end

      error = assert_raises(StandardError) { migrate_role_code!(:up) }
      refute_includes error.message, "   "
      assert_equal "#{MIGRATION_ABORT_PREFIX}1 row(s) with unmappable role", error.message
    ensure
      cleanup_member!(member_id)
      ensure_up!
    end

    test "down writes display labels then up restores every canonical role_code" do
      member_ids = ReplaceCareTeamMemberRoleWithRoleCode::ROLE_CODES.index_with do |code|
        insert_up_state_member!(role_code: code)
      end

      migrate_role_code!(:down)

      ReplaceCareTeamMemberRoleWithRoleCode::ROLE_LABELS.each do |code, label|
        assert_equal label, down_member_role(member_ids.fetch(code)),
                     "expected down migration label for #{code}"
      end

      migrate_role_code!(:up)

      ReplaceCareTeamMemberRoleWithRoleCode::ROLE_CODES.each do |code|
        assert_equal code, CareTeamMember.find(member_ids.fetch(code)).role_code
      end
    ensure
      member_ids&.each_value { |id| cleanup_member!(id) }
      ensure_up!
    end

    test "P4 replayed role_code migration CHECK definition matches schema-load baseline" do
      expected = fetch_check_constraint_definition(ReplaceCareTeamMemberRoleWithRoleCode::ROLE_CODE_CHECK)
      migrate_role_code!(:down)
      migrate_role_code!(:up)
      replayed = fetch_check_constraint_definition(ReplaceCareTeamMemberRoleWithRoleCode::ROLE_CODE_CHECK)
      assert_equal expected, replayed
    ensure
      ensure_up!
    end

    private

    def require_role_code_migration!
      paths = Dir[
        Rails.root.join("db/migrate/*_replace_care_team_member_role_with_role_code.rb").to_s,
        Corvid::Engine.root.join("db/migrate/*_replace_care_team_member_role_with_role_code.rb").to_s
      ]
      flunk "expected migration file matching *_replace_care_team_member_role_with_role_code.rb" if paths.empty?

      path = paths.first
      require path unless defined?(ReplaceCareTeamMemberRoleWithRoleCode)
      path
    end

    def migrate_role_code!(direction)
      ActiveRecord::Migration.suppress_messages do
        ReplaceCareTeamMemberRoleWithRoleCode.new.migrate(direction)
      end
      clear_migration_schema_caches!
    end

    def clear_migration_schema_caches!
      connection = ActiveRecord::Base.connection
      connection.clear_cache!
      connection.schema_cache.clear!
      CareTeamMember.reset_column_information
    end

    def with_migration_down
      migrate_role_code!(:down)
      yield
    end

    def ensure_up!
      migrate_role_code!(:up) if ctm_columns.include?("role")
    end

    def ctm_columns
      db_connection.columns(:corvid_care_team_members).map(&:name)
    end

    def db_connection
      ActiveRecord::Base.connection
    end

    def quote(value)
      db_connection.quote(value)
    end

    def insert_down_state_member!(role:)
      team = CareTeam.create!(name: "Mig down team", facility_identifier: FACILITY)
      now = Time.current
      db_connection.select_value(<<~SQL)
        INSERT INTO corvid_care_team_members
          (care_team_id, practitioner_identifier, role, lead, created_at, updated_at)
        VALUES
          (#{team.id.to_i}, #{quote("pr_mig_#{SecureRandom.hex(2)}")}, #{quote(role)}, false, #{quote(now)}, #{quote(now)})
        RETURNING id
      SQL
    end

    def insert_up_state_member!(role_code:)
      team = CareTeam.create!(name: "Mig up team", facility_identifier: FACILITY)
      CareTeamMember.create!(
        care_team: team,
        practitioner_identifier: "pr_mig_up_#{SecureRandom.hex(2)}",
        role_code: role_code
      ).id
    end

    def fetch_check_constraint_definition(name)
      db_connection.select_value(<<~SQL)
        SELECT pg_get_constraintdef(oid)
        FROM pg_constraint
        WHERE conname = #{quote(name)}
      SQL
    end

    def down_member_role(member_id)
      db_connection.select_value(<<~SQL)
        SELECT role FROM corvid_care_team_members WHERE id = #{member_id.to_i}
      SQL
    end

    def cleanup_member!(member_id)
      return if member_id.nil?

      CareTeamMember.unscoped.where(id: member_id).delete_all
    end
  end
end
