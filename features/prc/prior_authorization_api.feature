Feature: CMS-0057-F Prior Authorization API (Da Vinci PAS)
  As a payer required to comply with CMS-0057-F by January 1, 2027
  I need a Da Vinci PAS-conforming FHIR API for prior authorization
  So that providers can submit PA requests and receive decisions

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And a patient "pt_pa_001" with a PRC case

  # =============================================================================
  # PA SUBMISSION (Claim/$submit)
  # =============================================================================

  Scenario: Submit a new PA request via Claim/$submit
    When a provider submits a FHIR PA request for service "Cardiology Consultation" with estimated cost 5000
    Then a PrcReferral should be created in "submitted" status
    And the FHIR response should be a ClaimResponse with outcome "queued"
    And the ClaimResponse should reference the new PrcReferral

  Scenario: PA submission records provenance
    When a provider "pr_npi_1234567890" submits a FHIR PA request for service "MRI"
    Then a PrcReferral should be created
    And the PrcReferral should record the requesting provider as "pr_npi_1234567890"

  # =============================================================================
  # PA DECISION (ClaimResponse)
  # =============================================================================

  Scenario: Retrieve ClaimResponse for an approved referral
    Given an authorized PRC referral "rf_pa_approved" exists
    When I retrieve the ClaimResponse for "rf_pa_approved"
    Then the ClaimResponse outcome should be "complete"
    And the ClaimResponse disposition should be "approved"

  Scenario: Retrieve ClaimResponse for a denied referral
    Given a denied PRC referral "rf_pa_denied" exists with reason "Service not medically necessary"
    When I retrieve the ClaimResponse for "rf_pa_denied"
    Then the ClaimResponse outcome should be "complete"
    And the ClaimResponse disposition should be "denied"
    And the ClaimResponse should include the denial reason

  Scenario: Retrieve ClaimResponse for a pending referral
    Given a pending PRC referral "rf_pa_pending" exists in "committee_review" state
    When I retrieve the ClaimResponse for "rf_pa_pending"
    Then the ClaimResponse outcome should be "queued"
    And the ClaimResponse disposition should be "pended"

  # =============================================================================
  # BUNDLE SEARCH (list PA responses for a patient)
  # =============================================================================

  Scenario: List all ClaimResponses for a patient
    Given the following PRC referrals exist for patient "pt_pa_001":
      | identifier   | status     |
      | rf_pa_bundle_1 | authorized |
      | rf_pa_bundle_2 | denied     |
      | rf_pa_bundle_3 | submitted  |
    When I request all ClaimResponses for patient "pt_pa_001"
    Then the Bundle should contain 3 ClaimResponse entries

  # =============================================================================
  # COVERED SERVICES AND DOCUMENTATION
  # =============================================================================

  Scenario: Retrieve list of covered services
    When I request the list of covered items and services
    Then the response should list service categories requiring prior authorization

  Scenario: Retrieve documentation requirements for a service
    When I request documentation requirements for service "Cardiology Consultation"
    Then the response should list required clinical documentation

  # =============================================================================
  # REQUEST FOR MORE INFORMATION
  # =============================================================================

  Scenario: PA pended with request for more information
    Given a PRC referral "rf_pa_needs_info" exists
    When the referral is pended for additional clinical documentation
    And I retrieve the ClaimResponse for "rf_pa_needs_info"
    Then the ClaimResponse disposition should be "pended"
    And the ClaimResponse should list required additional information
