@stedi @claims
Feature: Stedi Claims Submission
  As a billing coordinator
  I want to submit claims electronically via Stedi
  So that I can receive faster reimbursement from payers

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And the billing adapter is configured
    And I am logged in as a billing_coordinator

  # =============================================================================
  # PROFESSIONAL CLAIMS (837P)
  # =============================================================================

  Scenario: Submit a professional claim for a completed service request
    Given a service request "2025-00123" exists with status "completed"
    And the service request has a patient with coverage
    And the service request has billing codes:
      | code  | description       | charge |
      | 99213 | Office Visit      | 150.00 |
    When I submit the service request as a professional claim
    Then the claim should be submitted successfully
    And I should see a Stedi claim ID
    And a claim submission record should be created with status "submitted"

  Scenario: Submit a professional claim with multiple line items
    Given a service request "2025-00124" exists with status "completed"
    And the service request has billing codes:
      | code  | description       | charge |
      | 99214 | Office Visit E/M  | 200.00 |
      | 36415 | Venipuncture      |  25.00 |
      | 85025 | CBC with Diff     |  45.00 |
    When I submit the service request as a professional claim
    Then the claim should be submitted successfully
    And the claim total should be "$270.00"

  Scenario: Professional claim includes required provider information
    Given a service request "2025-00125" exists with status "completed"
    And the requesting provider has NPI "1234567890"
    When I submit the service request as a professional claim
    Then the claim should include the provider NPI
    And the claim should include the provider taxonomy code

  Scenario: Professional claim fails validation when missing diagnosis
    Given a service request "2025-00126" exists with status "completed"
    And the service request has no diagnosis codes
    When I submit the service request as a professional claim
    Then the claim should fail validation
    And I should see error "Diagnosis code is required"

  # =============================================================================
  # INSTITUTIONAL CLAIMS (837I)
  # =============================================================================

  Scenario: Submit an institutional claim for an inpatient stay
    Given a service request "2025-00130" exists with status "completed"
    And the service request is for an inpatient facility service
    And the service request has revenue codes:
      | code | description | charge  |
      | 0120 | Room/Board  | 1500.00 |
      | 0250 | Pharmacy    |  350.00 |
    When I submit the service request as an institutional claim
    Then the claim should be submitted successfully
    And the claim type should be "837I"

  Scenario: Institutional claim includes facility information
    Given a service request "2025-00131" exists with status "completed"
    And the service request is for an inpatient facility service
    And the facility has NPI "0987654321"
    When I submit the service request as an institutional claim
    Then the claim should include the facility NPI
    And the claim should include the type of bill

  # =============================================================================
  # CLAIM TRACKING
  # =============================================================================

  Scenario: View claim submission status
    Given a claim submission exists for service request "2025-00123"
    And the claim has status "accepted"
    When I view the claim submission
    Then I should see the Stedi claim ID
    And I should see status "Accepted"
    And I should see the submission date

  @wip
  Scenario: Claim status updates from Stedi
    Given a claim submission exists with Stedi ID "CLM-STEDI-001"
    When Stedi reports the claim status changed to "paid"
    Then the claim submission status should be "paid"
    And the status change should be logged

  # =============================================================================
  # BATCH SUBMISSION
  # =============================================================================

  Scenario: Submit multiple claims in batch
    Given the following service requests are ready for billing:
      | identifier  | status    | claim_type |
      | 2025-00140  | completed | 837P       |
      | 2025-00141  | completed | 837P       |
      | 2025-00142  | completed | 837I       |
    When I submit all claims in batch
    Then 3 claims should be submitted
    And each claim should have a unique Stedi claim ID

  # =============================================================================
  # ERROR HANDLING
  # =============================================================================

  Scenario: Claim rejected by payer
    Given a service request "2025-00150" exists with status "completed"
    And the payer will reject the claim with reason "Invalid member ID"
    When I submit the service request as a professional claim
    Then the claim submission should have status "rejected"
    And I should see rejection reason "Invalid member ID"

  @wip
  Scenario: Claim submission fails due to network error
    Given a service request "2025-00151" exists with status "completed"
    And the Stedi API is unavailable
    When I submit the service request as a professional claim
    Then the claim submission should have status "error"
    And the error should be logged for retry

  # =============================================================================
  # AUDIT TRAIL
  # =============================================================================

  Scenario: Claim submission creates audit trail
    Given a service request "2025-00160" exists with status "completed"
    When I submit the service request as a professional claim
    Then a billing transaction should be logged
    And the transaction should have type "claim"
    And the transaction should have direction "outbound"
