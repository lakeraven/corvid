# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

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

    test "extra cell on row 2 raises InvalidFile and preserves prior rules" do
      with_tenant(TENANT) do
        existing = seed_existing_rule!
        csv = <<~CSV
          #{HEADER}
          payer_a,99213,,,,,required,2025-01-01,
          payer_b,99213,,,,,not_required,2025-01-01,,2025-06-30
        CSV

        error = assert_raises(PayerAuthorizationRuleLoader::InvalidFile) do
          PayerAuthorizationRuleLoader.load!(StringIO.new(csv), tenant_identifier: TENANT)
        end

        assert_match(/row 2/i, error.message)
        assert PayerAuthorizationRule.unscoped.exists?(id: existing.id)
        assert_equal 1, PayerAuthorizationRule.unscoped.where(tenant_identifier: TENANT).count
      end
    end

    test "short row 2 raises InvalidFile and preserves prior rules" do
      with_tenant(TENANT) do
        existing = seed_existing_rule!
        csv = <<~CSV
          #{HEADER}
          payer_a,99213,,,,,required,2025-01-01,
          payer_b,99213,,,,,not_required,2025-01-01
        CSV

        error = assert_raises(PayerAuthorizationRuleLoader::InvalidFile) do
          PayerAuthorizationRuleLoader.load!(StringIO.new(csv), tenant_identifier: TENANT)
        end

        assert_match(/row 2/i, error.message)
        assert PayerAuthorizationRule.unscoped.exists?(id: existing.id)
        assert_equal 1, PayerAuthorizationRule.unscoped.where(tenant_identifier: TENANT).count
      end
    end

    test "trailing blank line after data is ignored" do
      with_tenant(TENANT) do
        csv = "#{HEADER}\npayer_a,99213,,,,,required,2025-01-01,\n\n"
        count = PayerAuthorizationRuleLoader.load!(StringIO.new(csv), tenant_identifier: TENANT)

        assert_equal 1, count
        assert_equal 1, PayerAuthorizationRule.unscoped.where(tenant_identifier: TENANT).count
      end
    end

    test "create failure on row 2 rolls back tenant rules and raises InvalidFile" do
      with_tenant(TENANT) do
        existing = seed_existing_rule!
        csv = <<~CSV
          #{HEADER}
          payer_a,99213,,,,,required,2025-01-01,
          payer_a,99214,,,,,required,2025-01-01,
        CSV
        creates = 0
        real_create = PayerAuthorizationRule.method(:create!)
        stub_create = lambda do |attrs|
          creates += 1
          if creates == 2
            record = PayerAuthorizationRule.new(attrs)
            record.errors.add(:base, "stubbed invalid row")
            raise ActiveRecord::RecordInvalid, record
          end
          real_create.call(attrs)
        end

        error = assert_raises(PayerAuthorizationRuleLoader::InvalidFile) do
          PayerAuthorizationRule.stub(:create!, stub_create) do
            PayerAuthorizationRuleLoader.load!(StringIO.new(csv), tenant_identifier: TENANT)
          end
        end

        assert_match(/row 2/i, error.message)
        refute_match(/99213|99214|payer_a|stubbed/i, error.message)
        assert PayerAuthorizationRule.unscoped.exists?(id: existing.id)
        assert_equal 1, PayerAuthorizationRule.unscoped.where(tenant_identifier: TENANT).count
        refute PayerAuthorizationRule.unscoped.exists?(tenant_identifier: TENANT, service_code: "99213")
      end
    end

    test "load for tnt_test under tnt_other thread context replaces tnt_test only" do
      test_rule = seed_existing_rule!
      other_rule = seed_rule_for_tenant!(OTHER_TENANT, service_code: "99214")

      with_tenant(OTHER_TENANT) do
        count = PayerAuthorizationRuleLoader.load!(
          fixture_path("valid.csv"),
          tenant_identifier: TENANT
        )
        assert_equal 5, count
      end

      refute PayerAuthorizationRule.unscoped.exists?(id: test_rule.id)
      assert_equal 5, PayerAuthorizationRule.unscoped.where(tenant_identifier: TENANT).count
      assert PayerAuthorizationRule.unscoped.exists?(id: other_rule.id)
      assert_equal 1, PayerAuthorizationRule.unscoped.where(tenant_identifier: OTHER_TENANT).count
    end

    test "load for tnt_test with no tenant context replaces tnt_test rules" do
      test_rule = seed_existing_rule!
      Corvid::TenantContext.reset!

      count = PayerAuthorizationRuleLoader.load!(fixture_path("valid.csv"), tenant_identifier: TENANT)

      assert_equal 5, count
      refute PayerAuthorizationRule.unscoped.exists?(id: test_rule.id)
      assert_equal 5, PayerAuthorizationRule.unscoped.where(tenant_identifier: TENANT).count
    ensure
      Corvid::TenantContext.reset!
    end

    test "missing file path raises InvalidFile and preserves prior rules" do
      with_tenant(TENANT) do
        existing = seed_existing_rule!
        missing = fixture_path("no_such_payer_rules_792.csv")

        error = assert_raises(PayerAuthorizationRuleLoader::InvalidFile) do
          PayerAuthorizationRuleLoader.load!(missing, tenant_identifier: TENANT)
        end

        refute_match(/payer|99213|OLD99/i, error.message)
        assert PayerAuthorizationRule.unscoped.exists?(id: existing.id)
        assert_equal 1, PayerAuthorizationRule.unscoped.where(tenant_identifier: TENANT).count
      end
    end

    test "directory path raises InvalidFile and preserves prior rules" do
      with_tenant(TENANT) do
        existing = seed_existing_rule!
        directory = File.dirname(fixture_path("valid.csv"))

        error = assert_raises(PayerAuthorizationRuleLoader::InvalidFile) do
          PayerAuthorizationRuleLoader.load!(directory, tenant_identifier: TENANT)
        end

        refute_match(/payer|99213|valid/i, error.message)
        assert PayerAuthorizationRule.unscoped.exists?(id: existing.id)
        assert_equal 1, PayerAuthorizationRule.unscoped.where(tenant_identifier: TENANT).count
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

  class PayerAuthorizationRuleLoaderConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    TENANT = "tnt_test"

    setup do
      PayerAuthorizationRule.unscoped.where(tenant_identifier: TENANT).delete_all
    end

    teardown do
      PayerAuthorizationRule.unscoped.where(tenant_identifier: TENANT).delete_all
      Corvid::TenantContext.reset!
    end

    test "concurrent loads for one tenant serialize so the later file wins entirely" do
      a_paused = Queue.new
      release_a = Queue.new
      b_finished = Queue.new
      a_thread_id = nil
      a_create_calls = 0
      released = false
      thread_a = nil
      thread_b = nil
      real_create = PayerAuthorizationRule.method(:create!)
      restore_create = lambda do
        PayerAuthorizationRule.singleton_class.define_method(:create!) do |*args, **kwargs|
          real_create.call(*args, **kwargs)
        end
      end

      gate = lambda do |attrs|
        if Thread.current.object_id == a_thread_id
          a_create_calls += 1
          if a_create_calls == 1
            a_paused.push(true)
            release_a.pop(timeout: 5)
          end
        end
        real_create.call(attrs)
      end

      PayerAuthorizationRule.singleton_class.define_method(:create!, &gate)

      thread_a = Thread.new do
        a_thread_id = Thread.current.object_id
        ActiveRecord::Base.connection_pool.with_connection do
          with_tenant(TENANT) do
            PayerAuthorizationRuleLoader.load!(
              fixture_path("concurrency_tenant_a.csv"),
              tenant_identifier: TENANT
            )
          end
        end
      end

      a_paused.pop(timeout: 5)

      thread_b = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          with_tenant(TENANT) do
            PayerAuthorizationRuleLoader.load!(
              fixture_path("concurrency_tenant_b.csv"),
              tenant_identifier: TENANT
            )
            b_finished.push(true)
          end
        end
      end

      assert_nil b_finished.pop(timeout: 0.5), "second load finished while the first held the tenant lock"

      released = true
      release_a.push(true)
      thread_a.join(10)
      thread_b.join(10)

      rules = PayerAuthorizationRule.unscoped.where(tenant_identifier: TENANT).order(:id).to_a
      assert_equal 1, rules.size
      assert_equal "payer_b", rules.first.payer_identifier
      assert_equal "99214", rules.first.service_code
      assert_equal "not_required", rules.first.requirement
      refute PayerAuthorizationRule.unscoped.exists?(tenant_identifier: TENANT, service_code: "99213")
    ensure
      restore_create.call
      release_a.push(true) unless released
      thread_a&.join(1)
      thread_b&.join(1)
    end

    def fixture_path(name)
      File.expand_path("../../fixtures/files/payer_authorization_rules/#{name}", __dir__)
    end
  end
end
