# frozen_string_literal: true

require "test_helper"

module Corvid
  class CareTeamMemberRoleCodeTest < ActiveSupport::TestCase
    TENANT = "tnt_ctm_role_code"
    FACILITY = "fac_ctm_role_code"

    ROLE_CODES = %w[
      primary_care_provider
      care_manager
      consultant
      other
    ].freeze

    EXPECTED_ROLE_DISPLAY = {
      "primary_care_provider" => "Primary care provider",
      "care_manager" => "Care manager",
      "consultant" => "Consultant",
      "other" => "Other"
    }.freeze

    setup do
      Corvid::TenantContext.current_tenant_identifier = TENANT
    end

    ROLE_CODES.each do |code|
      test "role_display for #{code} returns fixed label text" do
        assert_role_code_implemented!
        member = create_member!(role_code: code)
        assert_equal EXPECTED_ROLE_DISPLAY.fetch(code), member.role_display
        refute_includes member.role_display, code.tr("_", " ")
      end
    end

    test "role_code is required" do
      assert_role_code_implemented!
      team = build_team
      member = team.care_team_members.build(practitioner_identifier: "pr_req")
      refute member.valid?
      assert member.errors[:role_code].any?
    end

    test "unknown role_code is invalid without surfacing the code in messages" do
      assert_role_code_implemented!
      member = build_member(role_code: "unknown_code")
      refute member.valid?
      assert member.errors[:role_code].any?
      member.errors.full_messages.each do |message|
        refute_includes message, "unknown_code"
      end
    end

    test "passing role to create! or update! raises UnknownAttributeError" do
      assert_role_code_implemented!
      refute_includes CareTeamMember.column_names, "role",
                      "free-text role must not remain a database column"
      member = create_member!(role_code: "other")
      assert_raises(ActiveRecord::UnknownAttributeError) do
        CareTeamMember.create!(
          care_team: build_team,
          practitioner_identifier: "pr_legacy",
          role: "PCP"
        )
      end
      assert_raises(ActiveRecord::UnknownAttributeError) do
        member.update!(role: "Care Manager")
      end
    end

    test "database CHECK rejects unknown role_code via update_columns" do
      assert_role_code_implemented!
      member = create_member!(role_code: "consultant")
      assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::CheckViolation) do
        CareTeamMember.transaction(requires_new: true) do
          member.update_columns(role_code: "bogus_code")
        end
      end
      assert_equal "consultant", member.reload.role_code
    end

    test "database CHECK rejects unknown role_code via raw SQL" do
      assert_role_code_implemented!
      member = create_member!(role_code: "other")
      assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::CheckViolation) do
        CareTeamMember.transaction(requires_new: true) do
          db_connection.exec_update(<<~SQL)
            UPDATE corvid_care_team_members
            SET role_code = 'bogus_code'
            WHERE id = #{member.id.to_i}
          SQL
        end
      end
      assert_equal "other", member.reload.role_code
    end

    [
      "primary_care",
      "Consultant",
      "other ",
      "care-manager"
    ].each do |near_miss|
      test "database CHECK rejects near-miss role_code #{near_miss.inspect}" do
        assert_role_code_implemented!
        member = create_member!(role_code: "consultant")
        assert_raises(ActiveRecord::StatementInvalid, ActiveRecord::CheckViolation) do
          CareTeamMember.transaction(requires_new: true) do
            db_connection.exec_update(<<~SQL)
              UPDATE corvid_care_team_members
              SET role_code = #{db_connection.quote(near_miss)}
              WHERE id = #{member.id.to_i}
            SQL
          end
        end
        assert_equal "consultant", member.reload.role_code
      end
    end

    private

    def db_connection
      ActiveRecord::Base.connection
    end

    def assert_role_code_implemented!
      assert_includes CareTeamMember.column_names, "role_code"
      refute_includes CareTeamMember.column_names, "role"
      assert_respond_to CareTeamMember.new, :role_display
    end

    def build_team
      CareTeam.create!(name: "Role code team", facility_identifier: FACILITY)
    end

    def build_member(**attrs)
      CareTeamMember.new(care_team: build_team, practitioner_identifier: "pr_#{SecureRandom.hex(2)}", **attrs)
    end

    def create_member!(**attrs)
      build_member(**attrs).tap(&:save!)
    end
  end
end
