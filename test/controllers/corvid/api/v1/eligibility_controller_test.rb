# frozen_string_literal: true

require "test_helper"

class Corvid::Api::V1::EligibilityControllerTest < ActionDispatch::IntegrationTest
  TENANT = "tenant_test"

  setup do
    Corvid::TenantContext.reset!
    Corvid.configure { |c| c.adapter = Corvid::Adapters::MockAdapter.new }
    Corvid::PrcEligibilityDecision.unscoped.delete_all
    Corvid::TenantContext.current_tenant_identifier = TENANT
  end

  teardown do
    Corvid::TenantContext.reset!
  end

  def headers
    { "X-Tenant-Identifier" => TENANT, "Content-Type" => "application/json" }
  end

  def check_body(person_id, **overrides)
    {
      person_identifier: person_id,
      facility: {
        identifier: "fac_demo",
        contracted_tribe_code: "DEMO",
        requires_on_reservation: false,
        requires_ssn_on_file: false
      }
    }.merge(overrides).to_json
  end

  test "check returns eligible for enrolled-in-contracted-tribe person" do
    Corvid.adapter.add_enrollment("pt_tp",
                                  enrolled: true, tribe_name: "Demo Tribe",
                                  tribe_code: "DEMO", member_status: "enrolled",
                                  confidence: :verified)

    post "/corvid/api/v1/eligibility/check", params: check_body("pt_tp"), headers: headers

    assert_response :success
    body = JSON.parse(response.body)
    assert body["eligible"]
    refute_nil body["decision_id"]
  end

  test "check returns ineligible for not-enrolled person with structured reason" do
    post "/corvid/api/v1/eligibility/check", params: check_body("pt_tn"), headers: headers

    assert_response :success
    body = JSON.parse(response.body)
    refute body["eligible"]
    assert_includes body["reason_codes"], "not_enrolled"
  end

  test "check returns ineligible for wrong-tribe enrollee with not_enrolled_in_contracted_tribe" do
    Corvid.adapter.add_enrollment("pt_wfp",
                                  enrolled: true, tribe_name: "Other Tribe",
                                  tribe_code: "OTHER", member_status: "enrolled",
                                  confidence: :verified)

    post "/corvid/api/v1/eligibility/check", params: check_body("pt_wfp"), headers: headers

    assert_response :success
    body = JSON.parse(response.body)
    refute body["eligible"]
    assert_includes body["reason_codes"], "not_enrolled_in_contracted_tribe"
  end

  test "check requires X-Tenant-Identifier header" do
    post "/corvid/api/v1/eligibility/check",
         params: check_body("pt_tp"),
         headers: { "Content-Type" => "application/json" }

    assert_response :bad_request
  end
end
