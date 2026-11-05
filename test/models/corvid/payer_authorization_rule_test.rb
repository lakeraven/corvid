# frozen_string_literal: true

require "test_helper"

module Corvid
  class PayerAuthorizationRuleTest < ActiveSupport::TestCase
    TENANT = "tnt_test"

    EXPECTED_COLUMNS = %w[
      id tenant_identifier payer_identifier service_code code_from code_to
      place_of_service plan_identifier requirement effective_on expires_on
      created_at updated_at
    ].freeze

    test "uses corvid_payer_authorization_rules and includes TenantScoped" do
      assert_equal "corvid_payer_authorization_rules", PayerAuthorizationRule.table_name
      assert PayerAuthorizationRule.included_modules.include?(TenantScoped)
    end

    test "column set matches the payer authorization rule contract" do
      assert_equal EXPECTED_COLUMNS.sort, PayerAuthorizationRule.column_names.sort
    end

    test "valid exact service_code row passes validation" do
      with_tenant(TENANT) do
        rule = PayerAuthorizationRule.new(
          payer_identifier: "payer_a",
          service_code: "99213",
          requirement: "required",
          effective_on: Date.new(2025, 1, 1)
        )
        assert rule.valid?, rule.errors.full_messages.join(", ")
      end
    end

    test "valid code range row passes validation" do
      with_tenant(TENANT) do
        rule = PayerAuthorizationRule.new(
          payer_identifier: "payer_a",
          code_from: "70540",
          code_to: "70559",
          requirement: "not_required",
          effective_on: Date.new(2025, 1, 1)
        )
        assert rule.valid?, rule.errors.full_messages.join(", ")
      end
    end

    test "requirement must be required, not_required, or documentation_only" do
      with_tenant(TENANT) do
        rule = build_rule(requirement: "maybe")
        refute rule.valid?
        assert rule.errors[:requirement].any?
      end
    end

    test "exactly one of service_code or code range must be present" do
      with_tenant(TENANT) do
        neither = build_rule(service_code: nil, code_from: nil, code_to: nil)
        refute neither.valid?
        assert neither.errors[:base].any? || neither.errors[:service_code].any?

        both = build_rule(service_code: "99213", code_from: "70540", code_to: "70559")
        refute both.valid?
        assert both.errors[:base].any? || both.errors[:service_code].any?

        partial_range = build_rule(service_code: nil, code_from: "70540", code_to: nil)
        refute partial_range.valid?
      end
    end

    test "service_code must match five-character uppercase alphanumeric" do
      with_tenant(TENANT) do
        (%w[9921 992131 x9213] + [ "9921-", "99 13", "99213 " ]).each do |bad|
          rule = build_rule(service_code: bad)
          refute rule.valid?, "expected #{bad.inspect} to be rejected"
          assert rule.errors[:service_code].any?
        end

        mixed_alphanumeric = build_rule(service_code: "9921X")
        assert mixed_alphanumeric.valid?, mixed_alphanumeric.errors.full_messages.join(", ")
      end
    end

    test "code range endpoints must match code shape and ordering" do
      with_tenant(TENANT) do
        bad_shape = build_rule(service_code: nil, code_from: "7054", code_to: "70559")
        refute bad_shape.valid?

        reversed = build_rule(service_code: nil, code_from: "70559", code_to: "70540")
        refute reversed.valid?

        length_mismatch = build_rule(service_code: nil, code_from: "70540", code_to: "7055")
        refute length_mismatch.valid?

        pattern_mismatch = build_rule(service_code: nil, code_from: "10000", code_to: "6999F")
        refute pattern_mismatch.valid?
      end
    end

    test "valid J-prefixed code range passes validation" do
      with_tenant(TENANT) do
        rule = build_rule(service_code: nil, code_from: "J0000", code_to: "J9999")
        assert rule.valid?, rule.errors.full_messages.join(", ")
      end
    end

    test "valid F-suffix code range passes validation" do
      with_tenant(TENANT) do
        rule = build_rule(service_code: nil, code_from: "0001F", code_to: "9999F")
        assert rule.valid?, rule.errors.full_messages.join(", ")
      end
    end

    test "valid multi-letter endpoint code range passes validation" do
      with_tenant(TENANT) do
        rule = build_rule(service_code: nil, code_from: "A0000", code_to: "C9999")
        assert rule.valid?, rule.errors.full_messages.join(", ")
      end
    end

    test "expires_on must be on or after effective_on" do
      with_tenant(TENANT) do
        rule = build_rule(
          effective_on: Date.new(2025, 6, 1),
          expires_on: Date.new(2025, 5, 31)
        )
        refute rule.valid?
        assert rule.errors[:expires_on].any?
      end
    end

    test "payer_identifier cannot be blank after stripping" do
      with_tenant(TENANT) do
        rule = build_rule(payer_identifier: "   ")
        refute rule.valid?
        assert rule.errors[:payer_identifier].any?
      end
    end

    test "place_of_service cannot be blank when provided" do
      with_tenant(TENANT) do
        rule = build_rule(place_of_service: "  ")
        refute rule.valid?
        assert rule.errors[:place_of_service].any?
      end
    end

    test "plan_identifier cannot be blank when provided" do
      with_tenant(TENANT) do
        rule = build_rule(plan_identifier: "  ")
        refute rule.valid?
        assert rule.errors[:plan_identifier].any?
      end
    end

    test "database check rejects invalid requirement on insert_all!" do
      assert_db_check_rejects(requirement: "maybe")
    end

    test "database check rejects both code forms on insert_all!" do
      assert_db_check_rejects(service_code: "99213", code_from: "70540", code_to: "70559")
    end

    test "database check rejects neither code form on insert_all!" do
      assert_db_check_rejects(service_code: nil, code_from: nil, code_to: nil)
    end

    test "database check rejects malformed service_code on insert_all!" do
      assert_db_check_rejects(service_code: "9921")
    end

    test "database check rejects malformed code range on insert_all!" do
      assert_db_check_rejects(service_code: nil, code_from: "7054", code_to: "70559")
    end

    test "database check rejects code range with mismatched lengths on insert_all!" do
      assert_db_check_rejects(service_code: nil, code_from: "70540", code_to: "7055")
    end

    test "database check rejects code range with mismatched endpoint patterns on insert_all!" do
      assert_db_check_rejects(service_code: nil, code_from: "10000", code_to: "6999F")
    end

    test "database check rejects reversed code range on insert_all!" do
      assert_db_check_rejects(service_code: nil, code_from: "70559", code_to: "70540")
    end

    test "database check rejects expires_on before effective_on on insert_all!" do
      assert_db_check_rejects(
        effective_on: Date.new(2025, 6, 1),
        expires_on: Date.new(2025, 5, 31)
      )
    end

    test "database check rejects blank payer_identifier on insert_all!" do
      assert_db_check_rejects(payer_identifier: "   ")
    end

    test "database check rejects blank place_of_service on insert_all!" do
      assert_db_check_rejects(place_of_service: "  ")
    end

    test "database check rejects blank plan_identifier on insert_all!" do
      assert_db_check_rejects(plan_identifier: "  ")
    end

    test "insert_all! under tenant context does not persist another tenant_identifier" do
      with_tenant(TENANT) do
        row = raw_rule_row(tenant_identifier: "tnt_other")
        begin
          PayerAuthorizationRule.insert_all!([ row ])
        rescue ActiveRecord::StatementInvalid
          nil
        end
        assert_equal 0, PayerAuthorizationRule.unscoped.where(tenant_identifier: "tnt_other").count
      end
    end

    private

    def build_rule(**attrs)
      defaults = {
        payer_identifier: "payer_a",
        service_code: "99213",
        code_from: nil,
        code_to: nil,
        place_of_service: nil,
        plan_identifier: nil,
        requirement: "required",
        effective_on: Date.new(2025, 1, 1),
        expires_on: nil
      }
      PayerAuthorizationRule.new(defaults.merge(attrs))
    end

    def raw_rule_row(overrides = {})
      now = Time.current
      {
        tenant_identifier: TENANT,
        payer_identifier: "payer_a",
        service_code: "99213",
        code_from: nil,
        code_to: nil,
        place_of_service: nil,
        plan_identifier: nil,
        requirement: "required",
        effective_on: Date.new(2025, 1, 1),
        expires_on: nil,
        created_at: now,
        updated_at: now
      }.merge(overrides)
    end

    def assert_db_check_rejects(**overrides)
      assert_raises(ActiveRecord::StatementInvalid) do
        PayerAuthorizationRule.transaction(requires_new: true) do
          PayerAuthorizationRule.unscoped.insert_all!([ raw_rule_row(overrides) ])
        end
      end
    end
  end
end
