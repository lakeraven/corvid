Feature: Service Request PRC Authorization Workflow
  As a PRC case manager
  I want service requests to track workflow state
  So I can monitor authorization progress

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And a patient "pt_001" with a PRC case
    And a PRC referral "rf_wf_001" for that case

  Scenario: Service request transitions through eligibility review
    Given a service request in "submitted" workflow state
    When the request enters "eligibility_review" workflow state
    Then the service request status should be "active"
    And the SLA should be set to 1 day

  Scenario: Service request is authorized
    Given a service request in "committee_review" workflow state
    When the request workflow state changes to "authorized"
    Then the service request status should be "active"
    And the authorization should expire in 180 days
    And the status history should show the transition

  Scenario: Service request is denied
    Given a service request in "committee_review" workflow state
    When the request workflow state changes to "denied"
    Then the service request status should be "cancelled"
    And the status history should show the denial

  Scenario: SLA monitoring shows overdue requests
    Given a service request in "eligibility_review" workflow state
    And the SLA due date has passed
    Then the request should be flagged as overdue

  Scenario: Reviewer assignment is tracked
    Given a service request in "eligibility_review" workflow state
    When I assign reviewer with IEN "456"
    Then the request should show assigned reviewer IEN "456"
    And the status history should record the assignment

  Scenario: Authorization expiration
    Given an authorized service request from 181 days ago
    Then the authorization should be expired
