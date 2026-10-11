# frozen_string_literal: true

require "test_helper"

class Corvid::Api::V1::IndianHealthEligibilityControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = "tnt_example"
    @requester = "req_001"
    @agreement = "agr_001"
    @headers = {
      "X-Tenant-Identifier" => @tenant,
      "X-Requester-Identifier" => @requester,
      "X-Agreement-Reference" => @agreement,
      "Content-Type" => "application/json",
      "Accept" => "application/json"
    }

    Corvid.configure { |c| c.adapter = Corvid::Adapters::MockAdapter.new }
    @adapter = Corvid.adapter
    
    Corvid.configuration.indian_health_eligibility_ceiling = { limit: 10, period: 1.hour }
  end

  teardown do
    Corvid.configuration.indian_health_eligibility_ceiling = nil
    Corvid::TenantContext.reset!
  end

  test "POST /inquire returns 200 JSON with exact top-level keys and X-Message-Id header" do
    asserted_time = Time.zone.parse("2026-10-11 10:00:00Z")
    @adapter.add_service_eligibility("pt_001", {
      determination: :eligible,
      asserted_by: "fac_demo",
      determined_at: asserted_time,
      confidence: :verified
    })

    post "/corvid/api/v1/indian_health_eligibility/inquire", 
         params: { person_identifier: "pt_001" }.to_json, 
         headers: @headers

    assert_response :success
    
    json = JSON.parse(response.body)
    assert_equal %w[message_id answer data_source asserted_at verification_result].sort, json.keys.sort

    assert_equal "eligible", json["answer"]
    assert_equal "fac_demo", json["data_source"]
    assert_equal asserted_time.iso8601, json["asserted_at"]
    
    assert response.headers["X-Message-Id"].present?
    assert_equal response.headers["X-Message-Id"], json["message_id"]
  end

  test "verification_result matches FHIR R4 for eligible" do
    asserted_time = Time.zone.parse("2026-10-11 10:00:00Z")
    @adapter.add_service_eligibility("pt_001", {
      determination: :eligible,
      asserted_by: "fac_demo",
      determined_at: asserted_time,
      confidence: :verified,
      tribe_code: "123",
      basis: "descendant"
    })

    post "/corvid/api/v1/indian_health_eligibility/inquire", 
         params: { person_identifier: "pt_001" }.to_json, 
         headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    vr = json["verification_result"]

    assert_equal "validated", vr["status"]
    assert_equal asserted_time.iso8601, vr["statusDate"]
    assert_equal "fac_demo", vr.dig("primarySource", 0, "who", "display")

    # Assert no leaked evidence data
    response_body = response.body.downcase
    assert_not_includes response_body, "tribe"
    assert_not_includes response_body, "enroll"
    assert_not_includes response_body, "descent"
    assert_not_includes response_body, "basis"
    assert_not_includes response_body, "shareholder"
  end

  test "verification_result matches FHIR R4 for not_eligible" do
    @adapter.add_service_eligibility("pt_001", {
      determination: :not_eligible,
      asserted_by: "fac_demo",
      determined_at: Time.current,
      confidence: :verified
    })

    post "/corvid/api/v1/indian_health_eligibility/inquire", 
         params: { person_identifier: "pt_001" }.to_json, 
         headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    vr = json["verification_result"]

    assert_equal "val-fail", vr["status"]
  end

  test "verification_result matches FHIR R4 for unknown" do
    @adapter.add_service_eligibility("pt_001", {
      determination: :unknown,
      asserted_by: nil,
      determined_at: nil,
      confidence: :verified
    })

    post "/corvid/api/v1/indian_health_eligibility/inquire", 
         params: { person_identifier: "pt_001" }.to_json, 
         headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    vr = json["verification_result"]

    assert_equal "in-process", vr["status"]
    assert_nil vr["statusDate"]
    assert_nil vr["primarySource"]
  end

  test "verification_result matches FHIR R4 for unavailable" do
    @adapter.add_service_eligibility("pt_001", {
      determination: :unknown,
      asserted_by: nil,
      determined_at: nil,
      confidence: :unavailable
    })

    post "/corvid/api/v1/indian_health_eligibility/inquire", 
         params: { person_identifier: "pt_001" }.to_json, 
         headers: @headers

    assert_response :success
    json = JSON.parse(response.body)
    vr = json["verification_result"]

    assert_equal "in-process", vr["status"]
  end

  test "400 when person_identifier missing, blank, or not a string" do
    # Missing
    post "/corvid/api/v1/indian_health_eligibility/inquire", 
         params: {}.to_json, 
         headers: @headers
    assert_response :bad_request

    # Blank
    post "/corvid/api/v1/indian_health_eligibility/inquire", 
         params: { person_identifier: "  " }.to_json, 
         headers: @headers
    assert_response :bad_request

    # Not a string (array)
    post "/corvid/api/v1/indian_health_eligibility/inquire", 
         params: { person_identifier: ["pt_001"] }.to_json, 
         headers: @headers
    assert_response :bad_request
  end

  test "400 when requester headers missing" do
    post "/corvid/api/v1/indian_health_eligibility/inquire", 
         params: { person_identifier: "pt_001" }.to_json, 
         headers: @headers.except("X-Requester-Identifier")
    assert_response :bad_request

    post "/corvid/api/v1/indian_health_eligibility/inquire", 
         params: { person_identifier: "pt_001" }.to_json, 
         headers: @headers.except("X-Agreement-Reference")
    assert_response :bad_request
  end

  test "429 when ceiling exceeded" do
    Corvid.configuration.indian_health_eligibility_ceiling = { limit: 1, period: 1.hour }

    post "/corvid/api/v1/indian_health_eligibility/inquire", 
         params: { person_identifier: "pt_001" }.to_json, 
         headers: @headers
    assert_response :success

    post "/corvid/api/v1/indian_health_eligibility/inquire", 
         params: { person_identifier: "pt_002" }.to_json, 
         headers: @headers
    assert_response :too_many_requests
  end

  test "503 when ceiling not configured" do
    Corvid.configuration.indian_health_eligibility_ceiling = nil

    post "/corvid/api/v1/indian_health_eligibility/inquire", 
         params: { person_identifier: "pt_001" }.to_json, 
         headers: @headers
    assert_response :service_unavailable
  end

  test "old aian_exemption determine route is gone (404)" do
    assert_raises(ActionController::RoutingError) do
      post "/corvid/api/v1/aian_exemption/determine", params: { person_identifier: "pt_001" }.to_json, headers: @headers
    end
  end

  test "no list, search, or batch routes" do
    assert_raises(ActionController::RoutingError) do
      get "/corvid/api/v1/indian_health_eligibility", headers: @headers
    end

    assert_raises(ActionController::RoutingError) do
      get "/corvid/api/v1/indian_health_eligibility/inquiries", headers: @headers
    end

    assert_raises(ActionController::RoutingError) do
      post "/corvid/api/v1/indian_health_eligibility/batch", params: { person_identifiers: ["pt_001"] }.to_json, headers: @headers
    end
  end
end
