# frozen_string_literal: true

require "test_helper"

class Corvid::Api::V1::AianExemptionControllerTest < ActionDispatch::IntegrationTest
  TENANT = "tenant_test"

  setup do
    Corvid::TenantContext.reset!
    Corvid.configure { |c| c.adapter = Corvid::Adapters::MockAdapter.new }
    Corvid::AianExemptionDetermination.unscoped.delete_all
    Corvid::TenantContext.current_tenant_identifier = TENANT
  end

  teardown do
    Corvid::TenantContext.reset!
  end

  def headers
    { "X-Tenant-Identifier" => TENANT, "Content-Type" => "application/json" }
  end

  test "determine returns exempt with bases and a FHIR VerificationResult" do
    Corvid.adapter.add_enrollment("pt_api", enrolled: true, tribe_code: "DEMO", confidence: :verified)

    post "/corvid/api/v1/aian_exemption/determine",
         params: { person_identifier: "pt_api", as_of_date: "2027-03-01" }.to_json,
         headers: headers

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "exempt", body["status"]
    assert_equal [ "enrolled_tribal_member" ], body["bases"]
    refute_nil body["determination_id"]
    assert_equal "VerificationResult", body.dig("verification_result", "resourceType")
  end

  test "determine returns not_established when no source has evidence" do
    post "/corvid/api/v1/aian_exemption/determine",
         params: { person_identifier: "pt_none" }.to_json,
         headers: headers

    assert_response :success
    assert_equal "not_established", JSON.parse(response.body)["status"]
  end

  test "determine rejects a request without a person_identifier" do
    post "/corvid/api/v1/aian_exemption/determine", params: {}.to_json, headers: headers

    assert_response :bad_request
  end

  test "determine rejects a malformed as_of_date" do
    post "/corvid/api/v1/aian_exemption/determine",
         params: { person_identifier: "pt_api", as_of_date: "not-a-date" }.to_json,
         headers: headers

    assert_response :bad_request
  end

  test "determine rejects a lookback that is not a non-negative integer" do
    [ "abc", "-30", "1.5" ].each do |value|
      post "/corvid/api/v1/aian_exemption/determine",
           params: { person_identifier: "pt_api", itu_lookback_days: value }.to_json,
           headers: headers

      assert_response :bad_request, "expected 400 for itu_lookback_days=#{value.inspect}"
    end
  end

  test "determine requires the tenant header" do
    post "/corvid/api/v1/aian_exemption/determine",
         params: { person_identifier: "pt_api" }.to_json,
         headers: { "Content-Type" => "application/json" }

    assert_response :bad_request
  end
end
