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

  # =============================================================================
  # 42 CFR 136.61 — ALL RESOURCES MUST BE CHECKED
  # =============================================================================

  Scenario: Referral cannot advance past alternate resource review with unchecked resources
    Given all 12 alternate resource checks are created for the referral
    And only 5 checks have been verified
    Then the referral should have pending resource checks
    And the referral should not be ready for authorization

  Scenario: Referral advances when all resources are verified as exhausted
    Given all 12 alternate resource checks are created for the referral
    And all checks are verified as not enrolled or exhausted
    Then the referral should not have pending resource checks
    And the referral should be ready for authorization

  Scenario: Active coverage blocks authorization until exhausted or coordinated
    Given all 12 alternate resource checks are created for the referral
    And "medicaid" is verified as enrolled
    And all other checks are verified as not enrolled
    Then the referral should not be ready for authorization

  # =============================================================================
  # STALENESS AND RE-VERIFICATION
  # =============================================================================

  Scenario: Stale checks are flagged for re-verification at 30 days
    Given all 12 alternate resource checks are created for the referral
    And all checks were verified 31 days ago
    When I check for stale verifications
    Then all checks should be stale

  Scenario: Checks verified within 30 days are not stale
    Given all 12 alternate resource checks are created for the referral
    And all checks were verified 15 days ago
    When I check for stale verifications
    Then no checks should be stale

  # =============================================================================
  # COST OPTIMIZATION — REUSE ACROSS REFERRALS
  # =============================================================================

  Scenario: Recent checks for same patient can seed a new referral
    Given a previous referral "rf_prev" for patient "pt_001" with all checks verified 10 days ago
    And a new PRC referral "rf_new" for that case
    When I seed alternate resource checks from the previous referral
    Then the new referral should have 12 checks
    And all new checks should be pre-populated from the previous verification
    And no new checks should be stale

  Scenario: Stale checks from previous referral are not reused
    Given a previous referral "rf_old" for patient "pt_001" with all checks verified 45 days ago
    And a new PRC referral "rf_new2" for that case
    When I seed alternate resource checks from the previous referral
    Then the new referral should have 12 checks
    And all new checks should be stale
    And all new checks should require re-verification

  # =============================================================================
  # FAILURE SCENARIOS
  # =============================================================================

  Scenario: Clearinghouse timeout leaves check in checking state
    Given an alternate resource check for "medicare_a" exists with status "not_checked"
    When the eligibility check times out
    Then the check status should be "checking"
    And the check should still count as pending

  Scenario: Clearinghouse returns error for invalid subscriber
    Given an alternate resource check for "private_insurance" exists with status "not_checked"
    When the eligibility check returns an error
    Then the check status should be "not_checked"
    And the check should still count as pending

  Scenario: Patient loses coverage between check and authorization
    Given an alternate resource check for "medicaid" exists with status "enrolled"
    And the check was verified 25 days ago
    When the patient's coverage is terminated
    And I re-verify the check
    Then the check status should be "not_enrolled"

  Scenario: Batch verification with mixed results
    Given all 12 alternate resource checks are created for the referral
    When I verify all and 2 return enrolled and 3 return errors
    Then 2 checks should have status "enrolled"
    Then 3 checks should still be pending
    And 7 checks should have status "not_enrolled"
    And the referral should not be ready for authorization
