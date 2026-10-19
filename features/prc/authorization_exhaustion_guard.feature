# frozen_string_literal: true

Feature: Alternate resource exhaustion before authorization
  As a PRC coordinator
  I want authorization blocked until every alternate resource is determined
  So that PRC pays only as payer of last resort per 42 CFR 136.61

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And a patient "pt_test_001" with a PRC case
    And a PRC referral "rf_exhaust_guard_001" for that case

  Scenario: A referral cannot be authorized before its alternate resources are exhausted
    Given the referral has reached "in alternate-resource review"
    And the referral does not require committee review
    And the following alternate resource checks exist:
      | resource_type     | status       |
      | medicare_a        | not_enrolled |
      | medicare_b        | not_enrolled |
      | medicare_d        | not_enrolled |
      | medicaid          | enrolled     |
      | va_benefits       | not_enrolled |
      | private_insurance | not_enrolled |
      | workers_comp      | not_enrolled |
      | auto_insurance    | not_enrolled |
      | liability_coverage| not_enrolled |
      | state_program     | not_enrolled |
      | tribal_program    | not_enrolled |
      | charity_care      | not_enrolled |
    When the Referral Specialist attempts to verify alternate resources
    Then the referral should be "in alternate-resource review"
    And the referral should show authorization blocker "medicaid: enrolled (coordination of benefits not complete)"
    When the alternate resource check for "medicaid" is set to "coordinated"
    And the Referral Specialist verifies alternate resources
    And the Referral Specialist completes priority assignment
    Then the referral should be "authorized"
