Feature: Medicaid primary payer — PRC referral workflow
  As a PRC coordinator at a tribal health programme
  I need an out-of-facility referral to proceed with Medicaid as payer when coverage is active
  So that the programme's capped appropriation is not obligated as payer of last resort

  # End-to-end chain (eligibility → coverage designation → authorization). Medicaid
  # enrollment verification mechanics live in alternate_resources.feature; this file
  # specifies consequences for the purchased/referred-care programme only.

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And facility "fac_test" is a tribal health programme facility
    And a patient "pt_med_001" enrolled as AI/AN with a PRC case
    And the adapter has enrollment data for patient "pt_med_001":
      | enrolled | membership_number | tribe_name   | on_reservation | address                              | ssn_last4 | dob        |
      | true     | TST-88421           | Example Tribe | true           | 100 Cedar Ln, Example City, WA 98901 | 2244      | 1978-04-12 |
    And a PRC referral "rf_med_001" for that case
    And the referral was submitted by "spec_referral_001"
    And the referral estimated cost is "$8,500"
    And the referral requests outside specialty care "Cardiology consultation"

  # =============================================================================
  # ELIGIBILITY — FHIR auto-fill vs staff attestation
  # =============================================================================

  # Catches treating a blank checklist as “eligible” before FHIR enrollment/identity/residency run.
  Scenario: Eligibility checklist auto-fills enrollment identity and residency from FHIR
    When the referral transitions through submit and begin_eligibility_review
    Then the checklist should have 3 of 7 items complete
    And "enrollment_verified" should be true
    And "identity_verified" should be true
    And "residency_verified" should be true
    And "application_complete" should be false
    And "clinical_necessity_documented" should be false

  # Catches staff skipping manual items while still expecting authorization readiness.
  Scenario: Staff completes application clinical necessity and insurance verification
    Given the referral transitions through submit and begin_eligibility_review
    When I manually verify "application_complete" by "pr_staff_001"
    And staff runs a payer eligibility check for the referral and finds coverage
    And I manually verify "clinical_necessity_documented" with source "manual"
    Then "insurance_verified" should be true
    And the insurance verification source should be "payer_eligibility"
    And 6 non-approval items should be complete

  # =============================================================================
  # AUTHORIZATION — dual control on management approval
  # =============================================================================

  # Catches self-approval when submitter and approver are the same principal.
  Scenario: Management approval requires an approver distinct from the submitter
    Given the referral is in "management_approval" status
    And an eligibility checklist with all non-approval items complete
    When manager "spec_referral_001" approves the referral
    Then the referral should remain in "management_approval" status
    And the eligibility checklist should not have management approval

  # Catches blocking the whole Medicaid path when a different manager approves.
  Scenario: Distinct manager approval advances toward alternate resource review
    Given the referral is in "management_approval" status
    And an eligibility checklist with all non-approval items complete
    When manager "pr_mgr_001" approves the referral
    Then the referral should be in "alternate_resource_review" status

  # =============================================================================
  # OTHER COVERAGE — Medicaid active vs programme appropriation
  # =============================================================================

  # Catches obligating CHS/PRC funds when Medicaid is the primary payer (payer of last resort inversion).
  Scenario: Active Medicaid designates primary payer and does not obligate programme funds
    Given the medicaid referral has completed eligibility and management approval
    And all alternate resource checks are created for the referral
    And "medicaid" is verified as enrolled
    And all other checks are verified as not enrolled
    When Medicaid primary payer is recorded for the referral
    And the referral completes authorization as Medicaid-funded
    Then the referral primary payer should be "medicaid"
    And no programme appropriation should exist for the referral
    And the referral should be in "authorized" status

  # Catches the false economy of skipping appropriation when no alternate payer exists.
  Scenario: No alternate payer obligates programme appropriation at authorization
    Given a PRC referral "rf_med_prc_only" for that case
    And the referral was submitted by "spec_referral_002"
    And the referral estimated cost is "$8,500"
    And the medicaid referral has completed eligibility and management approval
    And all alternate resource checks are created for the referral
    And all checks are verified as not enrolled or exhausted
    When the referral completes authorization as programme-funded
    Then the referral primary payer should be "programme"
    And a programme appropriation should exist for the referral
    And the appropriation amount should be "$8,500"
