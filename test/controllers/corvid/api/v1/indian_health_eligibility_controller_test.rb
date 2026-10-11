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

  test "verification_result matches FHIR R4 for eligible and does not leak extra data" do
    asserted_time = Time.zone.parse("2026-10-11 10:00:00Z")
    @adapter.add_service_eligibility("pt_001", {
      determination: :eligible,
      asserted_by: "fac_demo",
      determined_at: asserted_time,
      confidence: :verified,
      tribe_code: "TRIBE_X9",
      basis: "BASIS_Q7",
      enrolled: "ENR_Z3"
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
    response_body = response.body
    assert_not_includes response_body, "TRIBE_X9"
    assert_not_includes response_body, "BASIS_Q7"
    assert_not_includes response_body, "ENR_Z3"
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

  test "503 when unavailable (e.g. confidence is unavailable)" do
    @adapter.add_service_eligibility("pt_001", {
      determination: :unknown,
      asserted_by: nil,
      determined_at: nil,
      confidence: :unavailable
    })

    post "/corvid/api/v1/indian_health_eligibility/inquire",
         params: { person_identifier: "pt_001" }.to_json,
         headers: @headers

    assert_response :service_unavailable
    json = JSON.parse(response.body)
    assert_includes json, "error"
    assert_includes json, "message_id"
    assert_equal response.headers["X-Message-Id"], json["message_id"]
  end

  test "503 when adapter returns determined_at as a Date for a decisive answer" do
    @adapter.add_service_eligibility("pt_001", {
      determination: :eligible,
      asserted_by: "fac_demo",
      determined_at: Date.today,
      confidence: :verified
    })

    post "/corvid/api/v1/indian_health_eligibility/inquire",
         params: { person_identifier: "pt_001" }.to_json,
         headers: @headers

    assert_response :service_unavailable
    json = JSON.parse(response.body)
    assert_includes json, "error"
    assert_includes json, "message_id"
    assert_equal response.headers["X-Message-Id"], json["message_id"]
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
         params: { person_identifier: [ "pt_001" ] }.to_json,
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

  test "429 when ceiling exceeded carries correlation" do
    Corvid.configuration.indian_health_eligibility_ceiling = { limit: 1, period: 1.hour }

    post "/corvid/api/v1/indian_health_eligibility/inquire",
         params: { person_identifier: "pt_001" }.to_json,
         headers: @headers
    assert_response :success

    post "/corvid/api/v1/indian_health_eligibility/inquire",
         params: { person_identifier: "pt_002" }.to_json,
         headers: @headers
    assert_response :too_many_requests

    json = JSON.parse(response.body)
    assert_includes json, "message_id"
    assert_equal response.headers["X-Message-Id"], json["message_id"]

    inquiry = Corvid::IndianHealthEligibilityInquiry.last
    assert_equal "refused", inquiry.answer
    assert_equal inquiry.message_id, json["message_id"]
  end

  test "503 when ceiling not configured" do
    Corvid.configuration.indian_health_eligibility_ceiling = nil

    post "/corvid/api/v1/indian_health_eligibility/inquire",
         params: { person_identifier: "pt_001" }.to_json,
         headers: @headers
    assert_response :service_unavailable
  end

  test "old aian_exemption determine route is gone (404)" do
    post "/corvid/api/v1/aian_exemption/determine", params: { person_identifier: "pt_001" }.to_json, headers: @headers
    assert_response :not_found
  end

  test "no list, search, or batch routes" do
    get "/corvid/api/v1/indian_health_eligibility", headers: @headers
    assert_response :not_found

    get "/corvid/api/v1/indian_health_eligibility/inquiries", headers: @headers
    assert_response :not_found

    post "/corvid/api/v1/indian_health_eligibility/batch", params: { person_identifiers: [ "pt_001" ] }.to_json, headers: @headers
    assert_response :not_found
  end

  test "a replay renders asserted_at exactly as the first answer did" do
    asserted_time = Time.new(2026, 10, 11, 10, 0, 0, "-06:00")
    @adapter.add_service_eligibility("pt_001", {
      determination: :eligible, asserted_by: "fac_demo",
      determined_at: asserted_time, confidence: :verified
    })

    post "/corvid/api/v1/indian_health_eligibility/inquire",
         params: { person_identifier: "pt_001" }.to_json, headers: @headers
    first = JSON.parse(response.body)

    post "/corvid/api/v1/indian_health_eligibility/inquire",
         params: { person_identifier: "pt_001" }.to_json,
         headers: @headers.merge("X-Requester-Identifier" => "req_002")
    replay = JSON.parse(response.body)

    assert_equal first["asserted_at"], replay["asserted_at"]
    assert_equal first.dig("verification_result", "statusDate"), replay.dig("verification_result", "statusDate")
    assert_equal asserted_time.to_i, Time.iso8601(replay["asserted_at"]).to_i
  end
end
