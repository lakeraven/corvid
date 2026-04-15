Feature: Eligibility checklist auto-population from enrollment adapter
  As a PRC eligibility reviewer
  I need the checklist to auto-populate from the enrollment adapter
  So that 3 of 7 items are filled automatically and staff only complete the rest

  Background:
    Given a tenant "tnt_yakama" with facility "fac_toppenish"
    And a patient "pt_001" with a PRC case
    And a PRC referral "rf_001" for that case
    And the adapter has enrollment data for patient "pt_001":
      | enrolled | membership_number | tribe_name | on_reservation | address                          | ssn_last4 | dob        |
      | true     | TEST-10042        | Test Tribe | true           | 123 Main St, Test City, WA 99999 | 4321      | 1985-06-15 |

  Scenario: Populate auto-fills enrollment, identity, and residency
    When I populate the eligibility checklist for the referral
    Then the checklist should have 3 of 7 items complete
    And "enrollment_verified" should be true
    And "identity_verified" should be true
    And "residency_verified" should be true
    And "application_complete" should be false
    And "insurance_verified" should be false
    And "clinical_necessity_documented" should be false
    And "management_approved" should be false

  Scenario: Populate creates the checklist if it does not exist
    When I populate the eligibility checklist for the referral
    Then the referral should have an eligibility checklist

  Scenario: Populate records adapter source on auto-filled items
    When I populate the eligibility checklist for the referral
    Then "enrollment_verified" should have source "mock"
    And "identity_verified" should have source "mock"
    And "residency_verified" should have source "mock"

  Scenario: Staff manually verifies remaining items
    Given I have populated the eligibility checklist for the referral
    When I manually verify "application_complete" by "pr_staff_001"
    And I manually verify "insurance_verified" with source "manual"
    And I manually verify "clinical_necessity_documented" with source "manual"
    Then the checklist should have 6 of 7 items complete
    And 6 non-approval items should be complete

  Scenario: Manager approves via the service
    Given I have populated the eligibility checklist for the referral
    And all non-approval items are manually verified
    When manager "pr_mgr_001" approves via the service
    Then the checklist should be complete

  Scenario: Non-enrolled patient gets no auto-fill for enrollment
    Given the adapter has enrollment data for patient "pt_002":
      | enrolled | membership_number | tribe_name | on_reservation | address                      | ssn_last4 | dob        |
      | false    |                   |            | false          | 450 First Ave, Other City, WA | 5678      | 1990-03-01 |
    And a second PRC referral "rf_002" for patient "pt_002"
    When I populate the eligibility checklist for the second referral
    Then "enrollment_verified" should be false
    And "residency_verified" should be false
    And "identity_verified" should be true
