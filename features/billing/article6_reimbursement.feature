Feature: Article 6 Reimbursement Reports
  As an IHS billing administrator
  I need to generate Article 6 reimbursement reports
  So that I can track state/county share of healthcare costs

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And the billing adapter is configured

  Scenario: Generate summary report for a date range
    Given there are paid claim submissions in the system
    When I generate an Article 6 summary report for the current quarter
    Then I should receive a report with total billed and paid amounts
    And the report should include state and county share splits

  Scenario: Report groups claims by provider
    Given there are paid claim submissions from multiple providers
    When I generate an Article 6 report grouped by provider
    Then each provider should have billed and paid totals

  Scenario: Report groups claims by quarter
    Given there are paid claim submissions across multiple quarters
    When I generate an Article 6 report grouped by quarter
    Then each quarter should have aggregated totals

  Scenario: Amounts come from ClaimSubmission, not recalculated
    Given there are paid claim submissions in the system
    When I generate an Article 6 summary report for the current quarter
    Then the billed amounts should match the sum of ClaimSubmission billed amounts
    And the paid amounts should match the sum of ClaimSubmission paid amounts

  Scenario: Report exports to CSV
    Given there are paid claim submissions in the system
    When I export an Article 6 report as CSV
    Then I should receive a CSV string with reimbursement headers
