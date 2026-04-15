Feature: PRC eligibility documentation checklist
  As a PRC program manager
  I need every referral to track required eligibility documentation
  So that audit findings for missing documentation are eliminated

  Background:
    Given a tenant "tnt_yakama" with facility "fac_toppenish"
    And a patient "pt_001" with a PRC case
    And a PRC referral "rf_001" for that case

  Scenario: New referral has an empty eligibility checklist
    When I create an eligibility checklist for the referral
    Then the checklist should have 0 of 7 items complete
    And the compliance percentage should be 0.0

  Scenario: Checklist tracks all 7 audit categories
    When I create an eligibility checklist for the referral
    Then the checklist should track these items:
      | item                          |
      | application_complete          |
      | identity_verified             |
      | insurance_verified            |
      | residency_verified            |
      | enrollment_verified           |
      | clinical_necessity_documented |
      | management_approved           |

  Scenario: Verifying an item records timestamp and source
    Given an eligibility checklist for the referral
    When I verify "enrollment_verified" with source "baseroll"
    Then "enrollment_verified" should be true
    And "enrollment_verified" should have a verification timestamp
    And "enrollment_verified" should have source "baseroll"

  Scenario: Verifying application records who completed it
    Given an eligibility checklist for the referral
    When I verify "application_complete" with source "manual" by "pr_mgr_001"
    Then "application_complete" should be true
    And "application_complete" should have been completed by "pr_mgr_001"

  Scenario: Management approval records the approver
    Given an eligibility checklist for the referral
    When I verify "management_approved" with source "manual" by "pr_mgr_001"
    Then "management_approved" should be true
    And "management_approved" should have been approved by "pr_mgr_001"

  Scenario: Checklist is complete when all 7 items are verified
    Given an eligibility checklist for the referral
    When all 7 items are verified
    Then the checklist should be complete
    And the compliance percentage should be 100.0
    And there should be no missing items

  Scenario: Checklist reports missing items
    Given an eligibility checklist for the referral
    When I verify "application_complete" with source "manual"
    And I verify "identity_verified" with source "baseroll"
    And I verify "enrollment_verified" with source "baseroll"
    Then the checklist should have 3 of 7 items complete
    And the missing items should include "insurance_verified"
    And the missing items should include "residency_verified"
    And the missing items should include "clinical_necessity_documented"
    And the missing items should include "management_approved"

  Scenario: Items except approval are complete (6 of 7)
    Given an eligibility checklist for the referral
    When I verify "application_complete" with source "manual"
    And I verify "identity_verified" with source "baseroll"
    And I verify "insurance_verified" with source "manual"
    And I verify "residency_verified" with source "baseroll"
    And I verify "enrollment_verified" with source "baseroll"
    And I verify "clinical_necessity_documented" with source "manual"
    Then 6 non-approval items should be complete
    But the checklist should not be complete
