Feature: Case Management
  As a care coordinator
  I want to manage patient cases
  So that I can track care relationships and referrals

  Background:
    Given a tenant "tnt_test" with facility "fac_test"

  # =============================================================================
  # CASE LIFECYCLE
  # =============================================================================

  Scenario: Create a new case for a patient
    Given a patient exists with DFN "12345"
    When I create a case for the patient
    Then a case should exist for patient "12345"
    And the case status should be "active"

  Scenario: Case is scoped to facility
    Given a patient exists with DFN "12345"
    And a case exists for patient DFN "12345"
    When I switch to facility "Other Facility" with code "OTH"
    Then I should not see the case

  Scenario: Close a case
    Given a patient exists with DFN "12345"
    And a case exists for patient DFN "12345"
    When I close the case
    Then the case status should be "closed"

  Scenario: Reactivate a closed case
    Given a patient exists with DFN "12345"
    And a closed case exists for the patient
    When I reactivate the case
    Then the case status should be "active"

  # =============================================================================
  # CASE AND REFERRALS
  # =============================================================================

  Scenario: Create referral for a case
    Given a patient exists with DFN "12345"
    And a case exists for patient DFN "12345"
    When I create a PRC referral for the case
    Then the case should have 1 referral

  Scenario: Case tracks multiple referrals
    Given a patient exists with DFN "12345"
    And a case exists for patient DFN "12345"
    And the case has 3 referrals
    Then the case should have 3 referrals

  # =============================================================================
  # PATIENT DATA CACHING
  # =============================================================================

  Scenario: Cache patient data for offline display
    Given a patient exists with DFN "12345" and name "John Smith"
    And a case exists for patient DFN "12345"
    When I cache the patient data
    Then the case display name should be "John Smith"

  Scenario: Display name falls back gracefully
    Given a case exists without cached patient data
    Then the case display name should be "Unknown Patient"
