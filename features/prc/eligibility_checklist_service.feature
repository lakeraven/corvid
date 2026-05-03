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

  Scenario: Auto-populates on begin_eligibility_review transition
    When the referral transitions through submit and begin_eligibility_review
    Then the referral should have an eligibility checklist
    And "enrollment_verified" should be true
    And "identity_verified" should be true
    And "residency_verified" should be true

  Scenario: Non-enrolled patient gets no auto-fill for enrollment
    Given the adapter has enrollment data for patient "pt_002":
      | enrolled | membership_number | tribe_name | on_reservation | address                      | ssn_last4 | dob        |
      | false    |                   |            | false          | 450 First Ave, Other City, WA | 5678      | 1990-03-01 |
    And a second PRC referral "rf_002" for patient "pt_002"
    When I populate the eligibility checklist for the second referral
    Then "enrollment_verified" should be false
    And "residency_verified" should be false
    And "identity_verified" should be true

  # =========================================================================
  # DEMO SCENARIOS
  # =========================================================================

  Scenario: Best case — all data present, 3 of 7 auto-verified
    Given the adapter has enrollment data for patient "pt_bestcase":
      | enrolled | membership_number | tribe_name   | on_reservation | address                       | ssn_last4 | dob        |
      | true     | YN-54321          | Yakama Nation | true           | 511 Elm St, Toppenish, WA     | 9876      | 1980-05-15 |
    And a patient "pt_bestcase" with a PRC case
    And a PRC referral "rf_bestcase" for that case
    When the referral transitions through submit and begin_eligibility_review
    Then the checklist should have 3 of 7 items complete
    And "enrollment_verified" should be true
    And "identity_verified" should be true
    And "residency_verified" should be true
    And "application_complete" should be false
    And "insurance_verified" should be false
    And "clinical_necessity_documented" should be false
    And "management_approved" should be false

  Scenario: Minimum data — enrolled with DOB only, no SSN, off-reservation
    Given the adapter has enrollment data for patient "pt_mindata":
      | enrolled | membership_number | tribe_name   | on_reservation | address | ssn_last4 | dob        |
      | true     | YN-99999          | Yakama Nation | false          |         |           | 1992-11-03 |
    And a patient "pt_mindata" with a PRC case
    And a PRC referral "rf_mindata" for that case
    When the referral transitions through submit and begin_eligibility_review
    Then the checklist should have 2 of 7 items complete
    And "enrollment_verified" should be true
    And "identity_verified" should be true
    And "residency_verified" should be false

  Scenario: Insurance auto-verified when coverage exists
    Given the adapter has enrollment data for patient "pt_insured":
      | enrolled | membership_number | tribe_name   | on_reservation | address                       | ssn_last4 | dob        |
      | true     | YN-77777          | Yakama Nation | true           | 200 Main St, Toppenish, WA    | 5678      | 1988-02-14 |
    And the adapter has coverage data for patient "pt_insured":
      | payer_name | plan_name   | coverage_type |
      | Medicare   | Medicare A  | medicare      |
    And a patient "pt_insured" with a PRC case
    And a PRC referral "rf_insured" for that case
    When the referral transitions through submit and begin_eligibility_review
    Then the checklist should have 4 of 7 items complete
    And "enrollment_verified" should be true
    And "identity_verified" should be true
    And "residency_verified" should be true
    And "insurance_verified" should be true

  Scenario: Insurance not verified when no coverage on file
    Given the adapter has enrollment data for patient "pt_uninsured":
      | enrolled | membership_number | tribe_name   | on_reservation | address                       | ssn_last4 | dob        |
      | true     | YN-88888          | Yakama Nation | true           | 300 Elm St, Toppenish, WA     | 9012      | 1970-09-30 |
    And a patient "pt_uninsured" with a PRC case
    And a PRC referral "rf_uninsured" for that case
    When the referral transitions through submit and begin_eligibility_review
    Then the checklist should have 3 of 7 items complete
    And "insurance_verified" should be false

  Scenario: Staff triggers payer eligibility check when no coverage on file
    Given the adapter has enrollment data for patient "pt_nocov":
      | enrolled | membership_number | tribe_name   | on_reservation | address                       | ssn_last4 | dob        |
      | true     | YN-55555          | Yakama Nation | true           | 400 Oak St, Toppenish, WA     | 3456      | 1965-04-10 |
    And a patient "pt_nocov" with a PRC case
    And a PRC referral "rf_nocov" for that case
    And the referral transitions through submit and begin_eligibility_review
    And "insurance_verified" should be false
    When staff runs a payer eligibility check for the referral and finds coverage
    Then "insurance_verified" should be true
    And the insurance verification source should be "eligibility_check"

  Scenario: Staff payer eligibility check finds no coverage
    Given the adapter has enrollment data for patient "pt_nocov2":
      | enrolled | membership_number | tribe_name   | on_reservation | address                       | ssn_last4 | dob        |
      | true     | YN-66666          | Yakama Nation | true           | 500 Pine St, Toppenish, WA    | 7890      | 1982-12-01 |
    And a patient "pt_nocov2" with a PRC case
    And a PRC referral "rf_nocov2" for that case
    And the referral transitions through submit and begin_eligibility_review
    When staff runs a payer eligibility check for the referral and finds no coverage
    Then "insurance_verified" should be false

  Scenario: Best case full workflow — enrollment through authorization
    Given the adapter has enrollment data for patient "pt_fullflow":
      | enrolled | membership_number | tribe_name   | on_reservation | address                       | ssn_last4 | dob        |
      | true     | YN-11111          | Yakama Nation | true           | 100 Treaty Rd, Toppenish, WA  | 1234      | 1975-08-20 |
    And the adapter has coverage data for patient "pt_fullflow":
      | payer_name | plan_name   | coverage_type |
      | Medicare   | Medicare A  | medicare      |
    And a patient "pt_fullflow" with a PRC case
    And a PRC referral "rf_fullflow" for that case
    When the referral transitions through submit and begin_eligibility_review
    And I manually verify "application_complete" by "pr_clerk_001"
    And I manually verify "clinical_necessity_documented" with source "manual"
    And I request management approval
    And manager "pr_mgr_cookie" approves the referral
    Then the eligibility checklist should be complete
    And the referral should be in "alternate_resource_review" status
