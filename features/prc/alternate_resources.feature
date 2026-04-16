Feature: Alternate resource tracking (payer of last resort)
  As a PRC coordinator
  I want to track all alternate resources for a patient
  So that IHS is correctly applied as payer of last resort per 42 CFR 136.61

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And a patient "pt_001" with a PRC case
    And a PRC referral "rf_alt_001" for that case

  Scenario: Create alternate resource check for Medicare
    When I create an alternate resource check for "medicare_a"
    Then an alternate resource check for "medicare_a" should exist
    And the check status should be "not_checked"

  Scenario: Record enrollment status for Medicaid
    When I create an alternate resource check for "medicaid" with status "enrolled"
    Then an alternate resource check for "medicaid" should exist
    And the check status should be "enrolled"
    And the check should indicate active coverage

  Scenario: All alternate resources must be exhausted for PRC authorization
    Given the following alternate resource checks exist:
      | resource_type      | status       |
      | medicare_a         | not_enrolled |
      | medicare_b         | not_enrolled |
      | medicaid           | exhausted    |
      | private_insurance  | denied       |
    When I check if alternate resources are exhausted
    Then all resources should be exhausted

  Scenario: Cannot confirm exhaustion if any resource has active coverage
    Given the following alternate resource checks exist:
      | resource_type      | status       |
      | medicare_a         | not_enrolled |
      | medicaid           | enrolled     |
    When I check if alternate resources are exhausted
    Then all resources should not be exhausted

  Scenario: Cannot confirm exhaustion if any check is pending
    Given the following alternate resource checks exist:
      | resource_type      | status       |
      | medicare_a         | not_enrolled |
      | medicaid           | checking     |
    When I check if alternate resources are exhausted
    Then all resources should not be exhausted
    And there should be pending resource checks

  Scenario: Track private insurance coverage details
    When I record private insurance coverage with:
      | payer_name    | Blue Cross Blue Shield |
      | policy_number | BC123456               |
      | group_number  | GRP789                 |
      | coverage_start| 2024-01-01             |
      | coverage_end  | 2024-12-31             |
    Then an alternate resource check for "private_insurance" should exist
    And the check status should be "enrolled"
    And the payer name should be "Blue Cross Blue Shield"
    And the policy number should be "BC123456"

  Scenario: View human-readable resource names
    When I create an alternate resource check for "medicare_a"
    Then the resource name should be "Medicare Part A"

  Scenario: Resource type is unique per referral
    Given an alternate resource check for "medicare_a" already exists
    When I try to create another check for "medicare_a"
    Then the check should be invalid
    And I should see an error about duplicate resource type

  Scenario: Coverage requires coordination when enrolled but not exhausted
    Given an alternate resource check exists with status "enrolled"
    Then the check should require coordination of benefits

  Scenario: Coverage does not require coordination when exhausted
    Given an alternate resource check exists with status "exhausted"
    Then the check should not require coordination of benefits

  Scenario: Track federal programs (Medicare, Medicaid, VA)
    Given the following alternate resource checks exist:
      | resource_type      | status       |
      | medicare_a         | not_enrolled |
      | medicare_b         | enrolled     |
      | medicaid           | denied       |
      | va_benefits        | not_checked  |
      | private_insurance  | enrolled     |
    When I filter for federal programs
    Then I should see 4 checks
    And I should not see "private_insurance"

  Scenario: Track private payers
    Given the following alternate resource checks exist:
      | resource_type        | status       |
      | private_insurance    | enrolled     |
      | workers_comp         | not_enrolled |
      | auto_insurance       | denied       |
      | liability_coverage   | not_checked  |
      | medicare_a           | enrolled     |
    When I filter for private payers
    Then I should see 4 checks
    And I should not see "medicare_a"

  # =============================================================================
  # ENROLLMENT VERIFICATION SERVICE INTEGRATION
  # =============================================================================

  Scenario: Verify Medicare enrollment through service
    Given an alternate resource check for "medicare_a" exists with status "not_checked"
    When I verify the enrollment status
    Then the check status should not be "not_checked"
    And the check should have response data

  Scenario: Verify all resources for a referral
    Given the following alternate resource checks exist:
      | resource_type      | status       |
      | medicare_a         | not_checked  |
      | medicaid           | not_checked  |
      | tribal_program     | not_checked  |
    When I verify all enrollment statuses for the referral
    Then all checks should have been verified

  Scenario: Create and verify all resource checks for a referral
    When I create all resource checks for the referral
    Then alternate resource checks should exist for all resource types
    When I verify all enrollment statuses for the referral
    Then all checks should have been verified

  Scenario: Stale verification triggers re-verification
    Given an alternate resource check for "medicare_a" exists with status "enrolled"
    And the check was verified 60 days ago
    When I check if the verification is stale
    Then the verification should be stale

  Scenario: Recent verification is not stale
    Given an alternate resource check for "medicare_a" exists with status "enrolled"
    And the check was verified 10 days ago
    When I check if the verification is stale
    Then the verification should not be stale
