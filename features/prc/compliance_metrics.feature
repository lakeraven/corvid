Feature: CMS-0057-F API usage metrics
  As a payer subject to CMS-0057-F annual reporting
  I need corvid to track API call volume and distinct users/apps/patients
  So that I can publish the required public metrics by March 31 each year

  Background:
    Given a tenant "tnt_metrics" with facility "fac_metrics"

  # ===========================================================================
  # PER-CALL RECORDING
  # ===========================================================================

  Scenario: Recording a PAS API call
    When I record an API call for "pas" endpoint "submit" patient "pt_m_001" app "app_ehr_a"
    Then there should be 1 API call logged for tenant "tnt_metrics"
    And the call should be scoped to api "pas" endpoint "submit"

  Scenario: Recording counts each call separately
    When I record 3 API calls for "pas" endpoint "submit" patient "pt_m_002" app "app_ehr_a"
    Then there should be 3 API calls logged for tenant "tnt_metrics"

  # ===========================================================================
  # ANNUAL AGGREGATION
  # ===========================================================================

  Scenario: Annual report counts unique patients
    When I record an API call for "pas" endpoint "submit" patient "pt_m_100" app "app_a"
    And I record an API call for "pas" endpoint "submit" patient "pt_m_100" app "app_a"
    And I record an API call for "pas" endpoint "submit" patient "pt_m_101" app "app_a"
    Then the annual report for tenant "tnt_metrics" should show 2 unique patients
    And the annual report for tenant "tnt_metrics" should show 3 total calls

  Scenario: Annual report counts unique apps
    When I record an API call for "pas" endpoint "submit" patient "pt_m_200" app "app_x"
    And I record an API call for "pas" endpoint "submit" patient "pt_m_201" app "app_y"
    And I record an API call for "pas" endpoint "submit" patient "pt_m_202" app "app_x"
    Then the annual report for tenant "tnt_metrics" should show 2 unique apps

  Scenario: Annual report breaks down calls by endpoint
    When I record an API call for "pas" endpoint "submit" patient "pt_m_300" app "app_a"
    And I record an API call for "pas" endpoint "read" patient "pt_m_300" app "app_a"
    And I record an API call for "pas" endpoint "read" patient "pt_m_300" app "app_a"
    Then the annual report for tenant "tnt_metrics" should show 1 calls to "submit"
    And the annual report for tenant "tnt_metrics" should show 2 calls to "read"

  # ===========================================================================
  # TENANT SCOPING
  # ===========================================================================

  Scenario: Metrics are tenant-scoped
    When I record an API call for "pas" endpoint "submit" patient "pt_m_400" app "app_a"
    And tenant "tnt_other" records an API call for "pas" endpoint "submit" patient "pt_m_401" app "app_b"
    Then the annual report for tenant "tnt_metrics" should show 1 total calls
    And the annual report for tenant "tnt_other" should show 1 total calls

  # ===========================================================================
  # API FILTERING
  # ===========================================================================

  Scenario: Annual report can filter by API
    When I record an API call for "pas" endpoint "submit" patient "pt_m_500" app "app_a"
    And I record an API call for "patient_access" endpoint "read" patient "pt_m_500" app "app_a"
    Then the annual report for tenant "tnt_metrics" api "pas" should show 1 total calls
    And the annual report for tenant "tnt_metrics" api "patient_access" should show 1 total calls

  # ===========================================================================
  # PAS INTEGRATION
  # ===========================================================================

  Scenario: Submitting a PA request records a metrics event
    Given a patient "pt_m_600" with a PRC case
    When a provider submits a FHIR PA request for service "MRI" with estimated cost 2000 as app "app_ehr_a"
    Then the annual report for tenant "tnt_metrics" api "pas" should show 1 total calls
    And the annual report for tenant "tnt_metrics" api "pas" should show 1 unique patients

  Scenario: Reading a ClaimResponse records a metrics event (not double-counted from submit)
    Given a patient "pt_m_700" with a PRC case
    And a PRC referral "rf_m_700" for that case
    When a host app reads ClaimResponse "rf_m_700" as app "app_ehr_a"
    Then the annual report for tenant "tnt_metrics" api "pas" should show 1 calls to "read"

  Scenario: Searching ClaimResponses records a search metrics event
    Given a patient "pt_m_800" with a PRC case
    When a host app searches ClaimResponses for patient "pt_m_800" as app "app_ehr_a"
    Then the annual report for tenant "tnt_metrics" api "pas" should show 1 calls to "search"

  Scenario: Retrieving covered services records a metrics event without a patient
    When a host app requests the covered services list as app "app_ehr_a"
    Then the annual report for tenant "tnt_metrics" api "pas" should show 1 calls to "covered_services"
    And the annual report for tenant "tnt_metrics" api "pas" should show 0 unique patients

  Scenario: Retrieving documentation requirements records a metrics event
    When a host app requests documentation requirements for "MRI" as app "app_ehr_a"
    Then the annual report for tenant "tnt_metrics" api "pas" should show 1 calls to "documentation"
