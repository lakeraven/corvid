# frozen_string_literal: true

# CMS-0057-F API usage metrics step definitions.

def record_call(api:, endpoint:, patient:, app:, tenant: nil)
  Corvid::TenantContext.with_tenant(tenant || @tenant) do
    Corvid::ApiMetricsService.record!(
      api: api, endpoint: endpoint,
      patient_identifier: patient, app_identifier: app
    )
  end
end

When("I record an API call for {string} endpoint {string} patient {string} app {string}") do |api, endpoint, patient, app|
  record_call(api: api, endpoint: endpoint, patient: patient, app: app)
end

When("I record {int} API calls for {string} endpoint {string} patient {string} app {string}") do |n, api, endpoint, patient, app|
  n.times { record_call(api: api, endpoint: endpoint, patient: patient, app: app) }
end

When("tenant {string} records an API call for {string} endpoint {string} patient {string} app {string}") do |tenant, api, endpoint, patient, app|
  record_call(api: api, endpoint: endpoint, patient: patient, app: app, tenant: tenant)
end

When("a provider submits a FHIR PA request for service {string} with estimated cost {int} as app {string}") do |service, cost, app|
  claim = {
    resourceType: "Claim",
    status: "active",
    use: "preauthorization",
    patient: { reference: "Patient/#{@case.patient_identifier}" },
    total: { value: cost, currency: "USD" },
    item: [ { productOrService: service } ]
  }
  Corvid::PriorAuthorizationApiService.submit_from_claim(claim, app_identifier: app)
end

When("a host app reads ClaimResponse {string} as app {string}") do |identifier, app|
  referral = Corvid::PrcReferral.find_by!(referral_identifier: identifier)
  Corvid::PriorAuthorizationApiService.read_claim_response(referral, app_identifier: app)
end

When("a host app searches ClaimResponses for patient {string} as app {string}") do |patient, app|
  Corvid::PriorAuthorizationApiService.bundle_for_patient(patient, app_identifier: app)
end

When("a host app requests the covered services list as app {string}") do |app|
  Corvid::PriorAuthorizationApiService.covered_services(app_identifier: app)
end

When("a host app requests documentation requirements for {string} as app {string}") do |service, app|
  Corvid::PriorAuthorizationApiService.documentation_requirements_for(service, app_identifier: app)
end

Then(/^there should be (\d+) API calls? logged for tenant "([^"]+)"$/) do |count, tenant|
  Corvid::TenantContext.with_tenant(tenant) do
    assert_equal count.to_i, Corvid::ApiCallLog.count
  end
end

Then("the call should be scoped to api {string} endpoint {string}") do |api, endpoint|
  Corvid::TenantContext.with_tenant(@tenant) do
    call = Corvid::ApiCallLog.last
    assert_equal api, call.api_name
    assert_equal endpoint, call.endpoint
  end
end

Then("the annual report for tenant {string} should show {int} unique patients") do |tenant, count|
  report = Corvid::ApiMetricsService.annual_report(tenant: tenant, year: Date.current.year)
  assert_equal count, report[:unique_patients]
end

Then("the annual report for tenant {string} should show {int} unique apps") do |tenant, count|
  report = Corvid::ApiMetricsService.annual_report(tenant: tenant, year: Date.current.year)
  assert_equal count, report[:unique_apps]
end

Then("the annual report for tenant {string} should show {int} total calls") do |tenant, count|
  report = Corvid::ApiMetricsService.annual_report(tenant: tenant, year: Date.current.year)
  assert_equal count, report[:total_calls]
end

Then(/^the annual report for tenant "([^"]+)" should show (\d+) calls? to "([^"]+)"$/) do |tenant, count, endpoint|
  report = Corvid::ApiMetricsService.annual_report(tenant: tenant, year: Date.current.year)
  assert_equal count.to_i, report[:calls_by_endpoint][endpoint].to_i
end

Then("the annual report for tenant {string} api {string} should show {int} total calls") do |tenant, api, count|
  report = Corvid::ApiMetricsService.annual_report(tenant: tenant, year: Date.current.year, api: api)
  assert_equal count, report[:total_calls]
end

Then("the annual report for tenant {string} api {string} should show {int} unique patients") do |tenant, api, count|
  report = Corvid::ApiMetricsService.annual_report(tenant: tenant, year: Date.current.year, api: api)
  assert_equal count, report[:unique_patients]
end

Then(/^the annual report for tenant "([^"]+)" api "([^"]+)" should show (\d+) calls? to "([^"]+)"$/) do |tenant, api, count, endpoint|
  report = Corvid::ApiMetricsService.annual_report(tenant: tenant, year: Date.current.year, api: api)
  assert_equal count.to_i, report[:calls_by_endpoint][endpoint].to_i
end
