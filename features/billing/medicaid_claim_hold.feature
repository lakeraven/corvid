@billing @claims
Feature: Medicaid pending-enrollment claim hold
  PRC claims must not bypass a pending Medicaid application while retroactive
  coverage may still apply.

  Background:
    Given a tenant "tnt_test" with facility "fac_a"
    And the billing adapter is configured
    And a held draft claim exists for patient "pt-test-001" with a medicaid hold override

  # Issue #639 gate round 4
  Scenario: Submit refuses unsaved patient change after medicaid hold override
    Given another patient has a pending in-window medicaid application
    When I assign the claim to that patient without saving
    And I attempt to submit the held claim
    Then the claim submit should be refused for pending medicaid
    And the clearinghouse should receive no claim submissions
