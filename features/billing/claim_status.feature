@stedi @claim-status
Feature: Stedi Claim Status Tracking
  As a billing coordinator
  I want to track the status of submitted claims
  So that I can follow up on pending claims and handle rejections

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And the billing adapter is configured
    And I am logged in as a billing_coordinator

  # =============================================================================
  # SINGLE CLAIM STATUS CHECK
  # =============================================================================

  Scenario: Check status of a submitted claim
    Given a claim submission exists with Stedi ID "CLM-2025-001"
    And the claim has status "submitted"
    When I check the status of the claim
    Then I should see the current status from Stedi
    And the claim status should be updated

  Scenario: Claim accepted by payer
    Given a claim submission exists with Stedi ID "CLM-2025-002"
    And the claim has status "submitted"
    And Stedi reports the claim is "accepted"
    When I check the status of the claim
    Then the claim status should be "accepted"
    And I should see the acceptance date

  Scenario: Claim paid by payer
    Given a claim submission exists with Stedi ID "CLM-2025-003"
    And the claim has status "accepted"
    And Stedi reports the claim is "paid" with amount "$120.00"
    When I check the status of the claim
    Then the claim status should be "paid"
    And the paid amount should be "$120.00"

  Scenario: Claim rejected by payer
    Given a claim submission exists with Stedi ID "CLM-2025-004"
    And the claim has status "submitted"
    And Stedi reports the claim is "rejected" with reason "Invalid member ID"
    When I check the status of the claim
    Then the claim status should be "rejected"
    And the rejection reason should be "Invalid member ID"

  Scenario: Claim pending with payer
    Given a claim submission exists with Stedi ID "CLM-2025-005"
    And the claim has status "submitted"
    And Stedi reports the claim is "pending"
    When I check the status of the claim
    Then the claim status should remain "submitted"
    And the last checked time should be updated

  # =============================================================================
  # BATCH STATUS CHECKING
  # =============================================================================

  Scenario: Check status of all pending claims
    Given the following claims are pending:
      | stedi_id      | current_status |
      | CLM-2025-010  | submitted      |
      | CLM-2025-011  | submitted      |
      | CLM-2025-012  | accepted       |
    When I check the status of all pending claims
    Then each claim should be checked with Stedi
    And claim statuses should be updated accordingly

  Scenario: Batch status check handles mixed results
    Given the following claims are pending:
      | stedi_id      | stedi_reports |
      | CLM-2025-020  | accepted      |
      | CLM-2025-021  | rejected      |
      | CLM-2025-022  | pending       |
    When I check the status of all pending claims
    Then claim "CLM-2025-020" should have status "accepted"
    And claim "CLM-2025-021" should have status "rejected"
    And claim "CLM-2025-022" should have status "submitted"

  # =============================================================================
  # BACKGROUND JOB
  # =============================================================================

  Scenario: Background job polls pending claims
    Given there are 5 pending claims older than 1 hour
    When the claim status polling job runs
    Then all 5 claims should be checked
    And the job should log its completion

  @wip
  Scenario: Background job skips recently checked claims
    Given a claim was checked 5 minutes ago
    And a claim was checked 2 hours ago
    When the claim status polling job runs
    Then only the claim checked 2 hours ago should be rechecked

  Scenario: Background job handles Stedi API errors gracefully
    Given there are 3 pending claims
    And the Stedi API returns an error for the second claim
    When the claim status polling job runs
    Then the first claim should be updated
    And the second claim should be marked for retry
    And the third claim should be updated

  # =============================================================================
  # STATUS HISTORY
  # =============================================================================

  Scenario: Status changes are logged
    Given a claim submission exists with Stedi ID "CLM-2025-030"
    And the claim has status "submitted"
    When the claim status changes to "accepted"
    Then a billing transaction should be logged
    And the transaction should show the status change

  Scenario: View claim status history
    Given a claim has gone through multiple status changes
    When I view the claim status history
    Then I should see all status transitions
    And I should see timestamps for each change

  # =============================================================================
  # NOTIFICATIONS
  # =============================================================================

  Scenario: Alert on claim rejection
    Given a claim submission exists with Stedi ID "CLM-2025-040"
    And the claim has status "submitted"
    When the claim is rejected with reason "Missing modifier"
    Then a rejection alert should be created
    And the billing coordinator should be notified

  @wip
  Scenario: Alert on claim payment
    Given a claim submission exists with Stedi ID "CLM-2025-041"
    And the claim has billed amount "$200.00"
    When the claim is paid with amount "$160.00"
    Then a payment alert should be created
    And the adjustment amount should be "$40.00"

  # =============================================================================
  # ERROR HANDLING
  # =============================================================================

  Scenario: Handle claim not found in Stedi
    Given a claim submission exists with Stedi ID "CLM-NOTFOUND"
    When I check the status of the claim
    Then I should see error "Claim not found"
    And the claim should be flagged for review

  Scenario: Handle Stedi API timeout
    Given a claim submission exists with Stedi ID "CLM-TIMEOUT"
    And the Stedi API times out
    When I check the status of the claim
    Then the check should fail gracefully
    And the claim should be queued for retry
