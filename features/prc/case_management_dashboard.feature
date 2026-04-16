Feature: Case Management Dashboard
  As a care team member
  I need a dashboard with workload metrics and referral pipeline
  So that I can manage my caseload effectively

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And a care team "Nuka Team" exists in the tenant
    And I am a member of "Nuka Team"

  Scenario: Dashboard shows workload metrics
    Given there are 3 active cases for "Nuka Team"
    And there are 2 tasks assigned to me
    When I view the case management dashboard
    Then I should see active case count of 3
    And I should see task count of 2

  Scenario: Dashboard shows referral pipeline summary
    Given there are referrals in various states for "Nuka Team"
    When I view the case management dashboard
    Then I should see the referral pipeline grouped by state

  Scenario: Dashboard filters by status
    Given there are 3 active cases for "Nuka Team"
    And there are 1 closed cases for "Nuka Team"
    When I view the case management dashboard filtered by "active"
    Then I should see only active cases

  Scenario: Dashboard shows data source indicator
    When I view the case management dashboard
    Then the dashboard should indicate data is sourced from RPMS

  Scenario: CaseDashboardService reads from AR tables synced from RPMS
    Given there are 2 active cases for "Nuka Team"
    When the CaseDashboardService computes metrics
    Then the metrics should include active case count
    And the metrics should include referral pipeline counts
    And the service should be read-only with no side effects
