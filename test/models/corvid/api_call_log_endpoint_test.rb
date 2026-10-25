# frozen_string_literal: true

require "test_helper"

class Corvid::ApiCallLogEndpointTest < ActiveSupport::TestCase
  TENANT = "tnt_api_call_log_endpoint"
  ENDPOINT_CHECK = "corvid_api_call_logs_endpoint_check"

  test "ENDPOINTS lists every allowed CMS PAS route name" do
    flunk "expected Corvid::ApiCallLog::ENDPOINTS" unless Corvid::ApiCallLog.const_defined?(:ENDPOINTS)

    expected = %w[submit read search covered_services documentation]
    assert_equal expected, Corvid::ApiCallLog::ENDPOINTS
    assert Corvid::ApiCallLog::ENDPOINTS.frozen?
  end

  test "model accepts each ENDPOINTS value" do
    flunk "expected Corvid::ApiCallLog::ENDPOINTS" unless Corvid::ApiCallLog.const_defined?(:ENDPOINTS)

    with_tenant(TENANT) do
      Corvid::ApiCallLog::ENDPOINTS.each do |endpoint|
        log = build_api_call_log(endpoint: endpoint)
        assert log.valid?, "expected #{endpoint.inspect} to be valid: #{log.errors.full_messages}"
        refute_includes log.errors[:endpoint], "is not included in the list"
      end
    end
  end

  test "model rejects disallowed endpoint values without echoing the value" do
    flunk "expected Corvid::ApiCallLog::ENDPOINTS" unless Corvid::ApiCallLog.const_defined?(:ENDPOINTS)

    with_tenant(TENANT) do
      {
        "" => "",
        nil => nil,
        "/Patient/pt_123" => "/Patient/pt_123",
        "Submit" => "Submit",
        "submit " => "submit ",
        "submit\n" => "submit\n"
      }.each do |endpoint, echoed|
        log = build_api_call_log(endpoint: endpoint)
        refute log.valid?
        assert log.errors[:endpoint].present?
        message = log.errors[:endpoint].join(" ")
        refute_includes message, echoed if echoed.is_a?(String) && !echoed.empty?
      end
    end
  end

  test "database enforces endpoint via check constraint" do
    with_tenant(TENANT) do
      assert endpoint_check_constraint_exists?, "expected #{ENDPOINT_CHECK} on corvid_api_call_logs"

      log = Corvid::ApiCallLog.create!(
        tenant_identifier: TENANT,
        api_name: "pas",
        endpoint: "submit",
        called_at: Time.current
      )

      violation = assert_raises(ActiveRecord::CheckViolation) do
        Corvid::ApiCallLog.transaction(requires_new: true) do
          log.update_columns(endpoint: "/Patient/pt_123")
        end
      end
      assert_includes violation.message, ENDPOINT_CHECK
    end
  end

  test "record! with unknown endpoint stores nothing and does not log the endpoint value" do
    flunk "expected Corvid::ApiCallLog::ENDPOINTS" unless Corvid::ApiCallLog.const_defined?(:ENDPOINTS)

    bad_endpoints = [ "/Patient/pt_123", "Claim/123/$submit" ]

    with_tenant(TENANT) do
      before = Corvid::ApiCallLog.count

      bad_endpoints.each do |bad|
        warnings = capture_warns do
          result = Corvid::ApiMetricsService.record!(api: :pas, endpoint: bad)
          assert_nil result
        end

        assert_equal before, Corvid::ApiCallLog.count
        refute_includes warnings, bad
      end
    end
  end

  private

  def build_api_call_log(endpoint:)
    Corvid::ApiCallLog.new(
      tenant_identifier: TENANT,
      api_name: "pas",
      endpoint: endpoint,
      called_at: Time.current
    )
  end

  def endpoint_check_constraint_exists?
    sql = <<~SQL.squish
      SELECT 1
      FROM pg_constraint c
      INNER JOIN pg_class t ON c.conrelid = t.oid
      WHERE t.relname = 'corvid_api_call_logs'
        AND c.conname = #{ActiveRecord::Base.connection.quote(ENDPOINT_CHECK)}
        AND c.contype = 'c'
      LIMIT 1
    SQL
    ActiveRecord::Base.connection.select_value(sql).present?
  end

  def capture_warns
    captured = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(captured)
    Rails.logger.level = ::Logger::WARN
    yield
    captured.string
  ensure
    Rails.logger = original_logger if original_logger
  end
end
