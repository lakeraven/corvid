# frozen_string_literal: true

require "test_helper"

class Corvid::Api::V1::DecisionsControllerTest < ActionDispatch::IntegrationTest
  TENANT = "tenant_test"

  setup do
    Corvid::TenantContext.reset!
    Corvid::PrcEligibilityDecision.unscoped.delete_all
    Corvid::TenantContext.current_tenant_identifier = TENANT

    @d1 = Corvid::PrcEligibilityDecision.create!(
      tenant_identifier: TENANT,
      person_identifier: "pt_a",
      facility_identifier: "fac_demo",
      decided_at: 2.hours.ago,
      as_of_date: Date.current,
      eligible: true,
      reason_codes: []
    )
    @d2 = Corvid::PrcEligibilityDecision.create!(
      tenant_identifier: TENANT,
      person_identifier: "pt_b",
      facility_identifier: "fac_demo",
      decided_at: 1.hour.ago,
      as_of_date: Date.current,
      eligible: false,
      reason_codes: [ "not_enrolled" ]
    )
  end

  teardown do
    Corvid::TenantContext.reset!
  end

  def headers
    { "X-Tenant-Identifier" => TENANT }
  end

  test "index returns recent decisions" do
    get "/corvid/api/v1/decisions", headers: headers
    assert_response :success
    rows = JSON.parse(response.body)
    assert_equal 2, rows.size
    assert_equal @d2.id, rows.first["id"], "ordered recent-first"
  end

  test "index filters by eligible=false" do
    get "/corvid/api/v1/decisions", params: { eligible: "false" }, headers: headers
    assert_response :success
    rows = JSON.parse(response.body)
    assert_equal 1, rows.size
    refute rows.first["eligible"]
  end

  test "index filters by person_identifier" do
    get "/corvid/api/v1/decisions", params: { person_identifier: "pt_a" }, headers: headers
    assert_response :success
    rows = JSON.parse(response.body)
    assert_equal 1, rows.size
    assert_equal "pt_a", rows.first["person_identifier"]
  end

  test "show returns the full decision detail" do
    get "/corvid/api/v1/decisions/#{@d1.id}", headers: headers
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @d1.id, body["id"]
    assert body.key?("verification_snapshot_hash"), "detail includes provenance"
    assert body.key?("decided_by_identifier")
  end

  test "show returns 404 for unknown id" do
    get "/corvid/api/v1/decisions/999999999", headers: headers
    assert_response :not_found
  end

  test "missing tenant header returns 400" do
    get "/corvid/api/v1/decisions", headers: {}
    assert_response :bad_request
  end
end
