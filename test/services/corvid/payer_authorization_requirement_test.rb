# frozen_string_literal: true

require "test_helper"

module Corvid
  class PayerAuthorizationRequirementTest < ActiveSupport::TestCase
    TENANT = "tnt_test"
    OTHER_TENANT = "tnt_other"
    ON = Date.new(2025, 6, 15)

    test "lookup returns a frozen Result with sorted rule_ids" do
      with_tenant(TENANT) do
        id = create_rule!(service_code: "99213", requirement: "required").id
        result = lookup(service_code: "99213")

        assert_instance_of PayerAuthorizationRequirement::Result, result
        assert result.frozen?
        assert result.rule_ids.frozen?
        assert_equal [ id ], result.rule_ids
        assert_equal :required, result.requirement
      end
    end

    test "no matching rule is unknown with empty rule_ids" do
      with_tenant(TENANT) do
        result = lookup(service_code: "99213")
        assert_equal :unknown, result.requirement
        assert_empty result.rule_ids
      end
    end

    test "never defaults to not_required when no rule matches" do
      with_tenant(TENANT) do
        refute_equal :not_required, lookup(service_code: "99213").requirement
      end
    end

    test "malformed service_code after normalization is unknown" do
      with_tenant(TENANT) do
        create_rule!(service_code: "99213", requirement: "required")
        assert_equal :unknown, lookup(service_code: "9921").requirement
        assert_equal :unknown, lookup(service_code: "992131").requirement
      end
    end

    test "lookup normalizes service_code by stripping and upcasing" do
      with_tenant(TENANT) do
        create_rule!(service_code: "99213", requirement: "required")
        assert_equal :required, lookup(service_code: " 99213 ").requirement
        assert_equal :required, lookup(service_code: "99213").requirement
      end
    end

    test "range rule covers inclusive string-sorted endpoints" do
      with_tenant(TENANT) do
        create_rule!(
          service_code: nil, code_from: "70540", code_to: "70559",
          requirement: "required"
        )
        assert_equal :required, lookup(service_code: "70551").requirement
        assert_equal :unknown, lookup(service_code: "7055").requirement
        assert_equal :unknown, lookup(service_code: "70560").requirement
      end
    end

    test "on must be a Date" do
      with_tenant(TENANT) do
        create_rule!(service_code: "99213", requirement: "required")
        [ nil, "2025-06-15", Time.zone.parse("2025-06-15"), Time.zone.parse("2025-06-15 12:00") ].each do |bad_on|
          result = lookup(service_code: "99213", on: bad_on)
          assert_equal :unknown, result.requirement, "expected unknown for on=#{bad_on.inspect}"
        end
      end
    end

    test "blank payer_identifier is unknown" do
      with_tenant(TENANT) do
        create_rule!(service_code: "99213", requirement: "required")
        assert_equal :unknown, lookup(payer_identifier: "", service_code: "99213").requirement
        assert_equal :unknown, lookup(payer_identifier: "  ", service_code: "99213").requirement
      end
    end

    test "blank tenant_identifier is unknown" do
      with_tenant(TENANT) do
        create_rule!(service_code: "99213", requirement: "required")
        assert_equal :unknown,
                     lookup(service_code: "99213", tenant_identifier: "").requirement
      end
    end

    test "effective_on boundary is inclusive" do
      with_tenant(TENANT) do
        create_rule!(
          service_code: "99213", requirement: "required",
          effective_on: ON, expires_on: nil
        )
        assert_equal :required, lookup(service_code: "99213", on: ON).requirement
        assert_equal :unknown, lookup(service_code: "99213", on: ON - 1).requirement
      end
    end

    test "expires_on boundary is inclusive last day" do
      with_tenant(TENANT) do
        create_rule!(
          service_code: "99213", requirement: "required",
          effective_on: ON - 10, expires_on: ON
        )
        assert_equal :required, lookup(service_code: "99213", on: ON).requirement
        assert_equal :unknown, lookup(service_code: "99213", on: ON + 1).requirement
      end
    end

    test "plan-specific rule beats payer-wide rule" do
      with_tenant(TENANT) do
        payer_wide = create_rule!(service_code: "99213", requirement: "not_required")
        plan_rule = create_rule!(
          service_code: "99213", plan_identifier: "plan_gold", requirement: "required"
        )
        result = lookup(service_code: "99213", plan_identifier: "plan_gold")
        assert_equal :required, result.requirement
        assert_equal [ plan_rule.id ], result.rule_ids
        refute_includes result.rule_ids, payer_wide.id
      end
    end

    test "place-of-service-specific rule beats payer-wide rule" do
      with_tenant(TENANT) do
        payer_wide = create_rule!(service_code: "99213", requirement: "not_required")
        pos_rule = create_rule!(
          service_code: "99213", place_of_service: "22", requirement: "required"
        )
        result = lookup(service_code: "99213", place_of_service: "22")
        assert_equal :required, result.requirement
        assert_equal [ pos_rule.id ], result.rule_ids
        refute_includes result.rule_ids, payer_wide.id
      end
    end

    test "plan and place of service together beat plan-only rule" do
      with_tenant(TENANT) do
        plan_only = create_rule!(
          service_code: "99213", plan_identifier: "plan_gold", requirement: "not_required"
        )
        plan_and_pos = create_rule!(
          service_code: "99213", plan_identifier: "plan_gold", place_of_service: "11",
          requirement: "required"
        )
        result = lookup(service_code: "99213", plan_identifier: "plan_gold", place_of_service: "11")
        assert_equal :required, result.requirement
        assert_equal [ plan_and_pos.id ], result.rule_ids
        refute_includes result.rule_ids, plan_only.id
      end
    end

    test "exact service_code beats overlapping range" do
      with_tenant(TENANT) do
        range = create_rule!(
          service_code: nil, code_from: "70540", code_to: "70559", requirement: "not_required"
        )
        exact = create_rule!(service_code: "70551", requirement: "required")
        result = lookup(service_code: "70551")
        assert_equal :required, result.requirement
        assert_equal [ exact.id ], result.rule_ids
        refute_includes result.rule_ids, range.id
      end
    end

    test "two payer-wide rules that disagree yield conflict" do
      with_tenant(TENANT) do
        first = create_rule!(service_code: "99213", requirement: "required")
        second = create_rule!(service_code: "99213", requirement: "not_required")
        result = lookup(service_code: "99213")
        assert_equal :conflict, result.requirement
        assert_equal [ first.id, second.id ].sort, result.rule_ids
      end
    end

    test "two payer-wide rules that agree include both deciding ids" do
      with_tenant(TENANT) do
        first = create_rule!(service_code: "99213", requirement: "required")
        second = create_rule!(service_code: "99213", requirement: "required")
        result = lookup(service_code: "99213")
        assert_equal :required, result.requirement
        assert_equal [ first.id, second.id ].sort, result.rule_ids
      end
    end

    test "plan-only and place-only rules that disagree yield conflict" do
      with_tenant(TENANT) do
        plan_rule = create_rule!(
          service_code: "99213", plan_identifier: "plan_gold", requirement: "required"
        )
        pos_rule = create_rule!(
          service_code: "99213", place_of_service: "11", requirement: "not_required"
        )
        result = lookup(
          service_code: "99213", plan_identifier: "plan_gold", place_of_service: "11"
        )
        assert_equal :conflict, result.requirement
        assert_equal [ plan_rule.id, pos_rule.id ].sort, result.rule_ids
      end
    end

    test "fail closed when place_of_service is nil and a pos-specific rule disagrees" do
      with_tenant(TENANT) do
        create_rule!(service_code: "99213", requirement: "not_required")
        create_rule!(service_code: "99213", place_of_service: "22", requirement: "required")

        assert_equal :unknown, lookup(service_code: "99213", place_of_service: nil).requirement
        assert_equal :not_required, lookup(service_code: "99213", place_of_service: "11").requirement
        assert_equal :required, lookup(service_code: "99213", place_of_service: "22").requirement
      end
    end

    test "blank place_of_service input is treated like nil for fail closed" do
      with_tenant(TENANT) do
        create_rule!(service_code: "99213", requirement: "not_required")
        create_rule!(service_code: "99213", place_of_service: "22", requirement: "required")

        assert_equal :unknown, lookup(service_code: "99213", place_of_service: "").requirement
        assert_equal :unknown, lookup(service_code: "99213", place_of_service: "  ").requirement
      end
    end

    test "fail closed when plan_identifier is nil and a plan-specific rule disagrees" do
      with_tenant(TENANT) do
        create_rule!(service_code: "99213", requirement: "not_required")
        create_rule!(service_code: "99213", plan_identifier: "plan_gold", requirement: "required")

        assert_equal :unknown, lookup(service_code: "99213", plan_identifier: nil).requirement
        assert_equal :not_required, lookup(service_code: "99213", plan_identifier: "plan_basic").requirement
        assert_equal :required, lookup(service_code: "99213", plan_identifier: "plan_gold").requirement
      end
    end

    test "blank plan_identifier input is treated like nil for fail closed" do
      with_tenant(TENANT) do
        create_rule!(service_code: "99213", requirement: "not_required")
        create_rule!(service_code: "99213", plan_identifier: "plan_gold", requirement: "required")

        assert_equal :unknown, lookup(service_code: "99213", plan_identifier: "").requirement
        assert_equal :unknown, lookup(service_code: "99213", plan_identifier: "  ").requirement
      end
    end

    test "fail closed when omitted inputs leave a plan-and-place rule possibly applicable" do
      with_tenant(TENANT) do
        create_rule!(service_code: "99213", requirement: "not_required")
        plan_and_pos = create_rule!(
          service_code: "99213", plan_identifier: "plan_gold", place_of_service: "22",
          requirement: "required"
        )

        assert_equal :unknown,
                     lookup(service_code: "99213", plan_identifier: nil, place_of_service: nil).requirement
        assert_equal :unknown,
                     lookup(service_code: "99213", plan_identifier: "plan_gold", place_of_service: nil).requirement
        assert_equal :unknown,
                     lookup(service_code: "99213", plan_identifier: nil, place_of_service: "22").requirement
        assert_equal :not_required,
                     lookup(service_code: "99213", plan_identifier: "plan_basic", place_of_service: nil).requirement
        result = lookup(service_code: "99213", plan_identifier: "plan_gold", place_of_service: "22")
        assert_equal :required, result.requirement
        assert_equal [ plan_and_pos.id ], result.rule_ids
      end
    end

    test "pos-specific rule that agrees with payer-wide does not force unknown" do
      with_tenant(TENANT) do
        create_rule!(service_code: "99213", requirement: "required")
        create_rule!(service_code: "99213", place_of_service: "11", requirement: "required")

        assert_equal :required, lookup(service_code: "99213", place_of_service: nil).requirement
      end
    end

    test "another tenant's rules never match a lookup for tnt_test" do
      seed_rule_for_tenant!(TENANT, service_code: "99213", requirement: "required")
      seed_rule_for_tenant!(OTHER_TENANT, service_code: "99213", requirement: "not_required")

      with_tenant(OTHER_TENANT) do
        result = lookup(service_code: "99213", tenant_identifier: TENANT)
        assert_equal :required, result.requirement
      end
    end

    test "lookup uses explicit tenant_identifier when thread context is another tenant" do
      seed_rule_for_tenant!(TENANT, service_code: "99213", requirement: "documentation_only")
      seed_rule_for_tenant!(OTHER_TENANT, service_code: "99213", requirement: "required")

      with_tenant(OTHER_TENANT) do
        result = lookup(service_code: "99213", tenant_identifier: TENANT)
        assert_equal :documentation_only, result.requirement
      end
    end

    test "lookup works with no tenant context when tenant_identifier is explicit" do
      seed_rule_for_tenant!(TENANT, service_code: "99213", requirement: "required")
      Corvid::TenantContext.reset!

      result = lookup(service_code: "99213", tenant_identifier: TENANT)
      assert_equal :required, result.requirement
    end

    test "payer_authorization_rules documentation names headers requirements unknown and conflict" do
      path = Corvid::Engine.root.join("docs/payer_authorization_rules.md")
      assert path.file?, "expected docs/payer_authorization_rules.md to exist"
      doc = path.read

      %w[
        payer_identifier service_code code_from code_to place_of_service
        plan_identifier requirement effective_on expires_on
      ].each do |header|
        assert_includes doc, header, "expected CSV header #{header} in payer_authorization_rules.md"
      end

      %w[required not_required documentation_only].each do |value|
        assert_includes doc, value, "expected requirement value #{value} in payer_authorization_rules.md"
      end

      assert_match(/\bunknown\b/i, doc)
      assert_match(/\bconflict\b/i, doc)
    end

    private

    def lookup(**kwargs)
      defaults = {
        payer_identifier: "payer_a",
        service_code: "99213",
        place_of_service: nil,
        plan_identifier: nil,
        on: ON,
        tenant_identifier: TENANT
      }
      PayerAuthorizationRequirement.lookup(**defaults.merge(kwargs))
    end

    def create_rule!(**attrs)
      defaults = {
        payer_identifier: "payer_a",
        service_code: "99213",
        code_from: nil,
        code_to: nil,
        place_of_service: nil,
        plan_identifier: nil,
        requirement: "required",
        effective_on: ON - 30,
        expires_on: nil
      }
      PayerAuthorizationRule.create!(defaults.merge(attrs))
    end

    def seed_rule_for_tenant!(tenant, **attrs)
      PayerAuthorizationRule.unscoped.create!(
        {
          tenant_identifier: tenant,
          payer_identifier: "payer_a",
          service_code: "99213",
          code_from: nil,
          code_to: nil,
          place_of_service: nil,
          plan_identifier: nil,
          requirement: "required",
          effective_on: ON - 30,
          expires_on: nil
        }.merge(attrs)
      )
    end
  end
end
