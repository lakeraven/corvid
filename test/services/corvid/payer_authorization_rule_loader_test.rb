# frozen_string_literal: true

require "test_helper"

module Corvid
  class PayerAuthorizationRuleLoaderTest < ActiveSupport::TestCase
    TENANT = "tnt_test"
    OTHER_TENANT = "tnt_other"

    HEADER = "payer_identifier,service_code,code_from,code_to,place_of_service,plan_identifier,requirement,effective_on,expires_on"

    test "load! replaces tenant rules from valid fixture and returns row count" do
      with_tenant(TENANT) do
        seed_existing_rule!
        path = fixture_path("valid.csv")
        count = PayerAuthorizationRuleLoader.load!(path, tenant_identifier: TENANT)

        assert_equal 5, count
        assert_equal 5, PayerAuthorizationRule.unscoped.where(tenant_identifier: TENANT).count
        refute PayerAuthorizationRule.unscoped.exists?(service_code: "OLD99")
      end
    end

    test "load! leaves other tenants rules untouched" do
      other_rule = seed_rule_for_tenant!(OTHER_TENANT, service_code: "99213")
      with_tenant(TENANT) do
        PayerAuthorizationRuleLoader.load!(fixture_path("valid.csv"), tenant_identifier: TENANT)
      end

      assert PayerAuthorizationRule.unscoped.exists?(id: other_rule.id)
      assert_equal 1, PayerAuthorizationRule.unscoped.where(tenant_identifier: OTHER_TENANT).count
    end

    test "header-only file clears tenant rules and returns zero" do
      with_tenant(TENANT) do
        seed_existing_rule!
        io = StringIO.new("#{HEADER}\n")
        count = PayerAuthorizationRuleLoader.load!(io, tenant_identifier: TENANT)

        assert_equal 0, count
        assert_equal 0, PayerAuthorizationRule.unscoped.where(tenant_identifier: TENANT).count
      end
    end

    test "blank tenant_identifier raises ArgumentError" do
      assert_raises(ArgumentError) do
        PayerAuthorizationRuleLoader.load!(fixture_path("valid.csv"), tenant_identifier: "  ")
      end
    end

    test "unknown requirement value loads nothing and preserves prior rules" do
      with_tenant(TENANT) do
        existing = seed_existing_rule!
        path = fixture_path("unknown_requirement.csv")

        error = assert_raises(PayerAuthorizationRuleLoader::InvalidFile) do
          PayerAuthorizationRuleLoader.load!(path, tenant_identifier: TENANT)
        end

        assert_match(/row 2/i, error.message)
        assert_match(/requirement/i, error.message)
        refute_match(/maybe/i, error.message)

        assert PayerAuthorizationRule.unscoped.exists?(id: existing.id)
        assert_equal 1, PayerAuthorizationRule.unscoped.where(tenant_identifier: TENANT).count
      end
    end

    test "invalid header rejects the file without loading rows" do
      with_tenant(TENANT) do
        existing = seed_existing_rule!
        csv = <<~CSV
          payer_identifier,service_code,bad_column,code_from,code_to,place_of_service,plan_identifier,requirement,effective_on,expires_on
          payer_a,99213,,,,,required,2025-01-01,
        CSV

        assert_raises(PayerAuthorizationRuleLoader::InvalidFile) do
          PayerAuthorizationRuleLoader.load!(StringIO.new(csv), tenant_identifier: TENANT)
        end

        assert PayerAuthorizationRule.unscoped.exists?(id: existing.id)
      end
    end

    test "missing payer on a data row loads nothing" do
      with_tenant(TENANT) do
        existing = seed_existing_rule!
        csv = <<~CSV
          #{HEADER}
          ,99213,,,,,required,2025-01-01,
        CSV

        error = assert_raises(PayerAuthorizationRuleLoader::InvalidFile) do
          PayerAuthorizationRuleLoader.load!(StringIO.new(csv), tenant_identifier: TENANT)
        end

        assert_match(/row 1/i, error.message)
        assert_match(/payer_identifier/i, error.message)
        assert PayerAuthorizationRule.unscoped.exists?(id: existing.id)
      end
    end

    test "both code forms on one row loads nothing" do
      with_tenant(TENANT) do
        existing = seed_existing_rule!
        csv = <<~CSV
          #{HEADER}
          payer_a,99213,70540,70559,,,required,2025-01-01,
        CSV

        error = assert_raises(PayerAuthorizationRuleLoader::InvalidFile) do
          PayerAuthorizationRuleLoader.load!(StringIO.new(csv), tenant_identifier: TENANT)
        end

        assert_match(/row 1/i, error.message)
        assert PayerAuthorizationRule.unscoped.exists?(id: existing.id)
      end
    end

    test "bad effective_on date loads nothing" do
      with_tenant(TENANT) do
        existing = seed_existing_rule!
        csv = <<~CSV
          #{HEADER}
          payer_a,99213,,,,,required,2025/01/01,
        CSV

        error = assert_raises(PayerAuthorizationRuleLoader::InvalidFile) do
          PayerAuthorizationRuleLoader.load!(StringIO.new(csv), tenant_identifier: TENANT)
        end

        assert_match(/row 1/i, error.message)
        assert_match(/effective_on/i, error.message)
        assert PayerAuthorizationRule.unscoped.exists?(id: existing.id)
      end
    end

    test "expires_on before effective_on loads nothing" do
      with_tenant(TENANT) do
        existing = seed_existing_rule!
        csv = <<~CSV
          #{HEADER}
          payer_a,99213,,,,,required,2025-06-01,2025-05-01
        CSV

        error = assert_raises(PayerAuthorizationRuleLoader::InvalidFile) do
          PayerAuthorizationRuleLoader.load!(StringIO.new(csv), tenant_identifier: TENANT)
        end

        assert_match(/row 1/i, error.message)
        assert PayerAuthorizationRule.unscoped.exists?(id: existing.id)
      end
    end

    test "strips and upcases codes from CSV cells" do
      with_tenant(TENANT) do
        csv = <<~CSV
          #{HEADER}
          payer_a, 99213 ,,,,,required,2025-01-01,
        CSV
        PayerAuthorizationRuleLoader.load!(StringIO.new(csv), tenant_identifier: TENANT)

        rule = PayerAuthorizationRule.unscoped.find_by!(tenant_identifier: TENANT, service_code: "99213")
        assert_equal "99213", rule.service_code
      end
    end

    private

    def fixture_path(name)
      File.expand_path("../../fixtures/files/payer_authorization_rules/#{name}", __dir__)
    end

    def seed_existing_rule!
      PayerAuthorizationRule.unscoped.create!(
        tenant_identifier: TENANT,
        payer_identifier: "payer_a",
        service_code: "OLD99",
        requirement: "required",
        effective_on: Date.new(2025, 1, 1)
      )
    end

    def seed_rule_for_tenant!(tenant, **attrs)
      PayerAuthorizationRule.unscoped.create!(
        {
          tenant_identifier: tenant,
          payer_identifier: "payer_a",
          service_code: "99213",
          requirement: "required",
          effective_on: Date.new(2025, 1, 1)
        }.merge(attrs)
      )
    end
  end
end
