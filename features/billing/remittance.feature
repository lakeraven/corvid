# frozen_string_literal: true

Feature: Stedi Remittance Processing (835)
  As a billing coordinator
  I want to receive and process electronic remittance advice
  So that I can reconcile claim payments and track adjustments

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And the billing adapter is configured

  # =============================================================================
  # FETCHING REMITTANCES
  # =============================================================================

  Scenario: Fetch remittances for a date range
    Given there are remittances from the last 7 days
    When I fetch remittances for the last 7 days
    Then I should receive a list of remittances
    And each remittance should have payment date and amount

  Scenario: Fetch single remittance detail
    Given a remittance exists with ID "REM-001"
    When I fetch remittance "REM-001"
    Then I should see the remittance details
    And I should see the claim payments included

  Scenario: Handle no remittances in date range
    Given there are no remittances for the date range
    When I fetch remittances for an empty date range
    Then I should receive an empty list
    And no error should occur

  # =============================================================================
  # MATCHING REMITTANCES TO CLAIMS
  # =============================================================================

  Scenario: Match remittance to existing claim
    Given a claim exists with Stedi ID "CLM-MATCH-001"
    And the claim has status "accepted"
    And a remittance includes payment for "CLM-MATCH-001"
    When I process the remittance
    Then the claim should be marked as paid
    And the paid amount should be recorded
    And the payment date should be recorded

  @wip
  Scenario: Match remittance with adjustment
    Given a claim exists with Stedi ID "CLM-ADJUST-001" and billed amount "$150.00"
    And the claim has status "accepted"
    And a remittance includes payment for "CLM-ADJUST-001" with amount "$120.00"
    And the remittance includes adjustments:
      | code   | amount | reason                      |
      | CO-45  | $30.00 | Contractual obligation      |
    When I process the remittance
    Then the claim should be marked as paid
    And the paid amount should be "$120.00"
    And the adjustment amount should be "$30.00"

  Scenario: Match remittance with patient responsibility
    Given a claim exists with Stedi ID "CLM-PATIENT-001" and billed amount "$200.00"
    And the claim has status "accepted"
    And a remittance includes payment for "CLM-PATIENT-001" with amount "$150.00"
    And the patient responsibility is "$50.00"
    When I process the remittance
    Then the claim should be marked as paid
    And the paid amount should be "$150.00"
    And the patient responsibility should be "$50.00"

  Scenario: Handle unmatched claim in remittance
    Given no claim exists with Stedi ID "CLM-UNKNOWN-001"
    And a remittance includes payment for "CLM-UNKNOWN-001"
    When I process the remittance
    Then a warning should be logged for unmatched claim
    And the remittance should be flagged for review

  Scenario: Handle duplicate remittance processing
    Given a claim exists with Stedi ID "CLM-DUP-001"
    And the claim is already paid
    And a remittance includes payment for "CLM-DUP-001"
    When I process the remittance
    Then the payment should be skipped
    And a duplicate warning should be logged

  # =============================================================================
  # BATCH PROCESSING
  # =============================================================================

  Scenario: Process multiple claims in one remittance
    Given these claims exist:
      | stedi_id       | status   | billed_amount |
      | CLM-BATCH-001  | accepted | $100.00       |
      | CLM-BATCH-002  | accepted | $200.00       |
      | CLM-BATCH-003  | accepted | $300.00       |
    And a remittance includes payments for all three claims
    When I process the remittance
    Then all three claims should be marked as paid
    And the total paid amount should be calculated

  Scenario: Continue processing after individual match failure
    Given these claims exist:
      | stedi_id       | status   |
      | CLM-ERR-001    | accepted |
      | CLM-ERR-003    | accepted |
    And a remittance includes payments:
      | claim_id      | amount  |
      | CLM-ERR-001   | $100.00 |
      | CLM-UNKNOWN   | $50.00  |
      | CLM-ERR-003   | $75.00  |
    When I process the remittance
    Then claim "CLM-ERR-001" should be paid
    And claim "CLM-ERR-003" should be paid
    And the unmatched payment should be logged

  # =============================================================================
  # BACKGROUND JOB
  # =============================================================================

  Scenario: Remittance polling job processes new remittances
    Given there are unprocessed remittances from today
    When the remittance polling job runs
    Then new remittances should be fetched
    And matching claims should be updated
    And the job should log its completion

  Scenario: Polling job skips already processed remittances
    Given a remittance was already processed yesterday
    When the remittance polling job runs
    Then the remittance should not be processed again

  Scenario: Polling job handles API errors gracefully
    Given the Stedi API returns an error
    When the remittance polling job runs
    Then the job should log the error
    And the job should not fail

  # =============================================================================
  # DENIAL AND REJECTION HANDLING
  # =============================================================================

  Scenario: Handle claim denial in remittance
    Given a claim exists with Stedi ID "CLM-DENIED-001"
    And the claim has status "accepted"
    And a remittance includes denial for "CLM-DENIED-001" with reason "Service not covered"
    When I process the remittance
    Then the claim should be marked as rejected
    And the rejection reason should be "Service not covered"

  Scenario: Handle partial denial with adjustment codes
    Given a claim exists with Stedi ID "CLM-PARTIAL-001" and billed amount "$500.00"
    And the claim has status "accepted"
    And a remittance includes payment for "CLM-PARTIAL-001":
      | paid_amount | $350.00                     |
      | adjustment  | CO-45:$100.00               |
      | denial      | CO-97:$50.00 (Not covered)  |
    When I process the remittance
    Then the claim should be marked as paid
    And the paid amount should be "$350.00"
    And the adjustment codes should be recorded

  # =============================================================================
  # AUDIT TRAIL
  # =============================================================================

  Scenario: Remittance processing is logged
    Given a claim exists with Stedi ID "CLM-AUDIT-001"
    And a remittance includes payment for "CLM-AUDIT-001"
    When I process the remittance
    Then a billing transaction should be logged
    And the transaction should be type "remittance"
    And the transaction should be direction "inbound"

  Scenario: View remittance history for a claim
    Given a claim exists with Stedi ID "CLM-HISTORY-001"
    And the claim has received multiple remittances
    When I view the claim remittance history
    Then I should see all remittance events
    And I should see timestamps for each event

  # =============================================================================
  # STATISTICS AND REPORTING
  # =============================================================================

  Scenario: Calculate payment statistics
    Given these paid claims exist:
      | stedi_id  | billed_amount | paid_amount |
      | CLM-S001  | $100.00       | $80.00      |
      | CLM-S002  | $200.00       | $180.00     |
      | CLM-S003  | $150.00       | $150.00     |
    When I calculate remittance statistics
    Then the total billed should be "$450.00"
    And the total paid should be "$410.00"
    And the average payment rate should be "91.1%"

  Scenario: Get pending remittance count
    Given there are 5 unprocessed remittances
    When I check the pending remittance count
    Then the count should be 5

  # =============================================================================
  # ERROR HANDLING
  # =============================================================================

  Scenario: Handle invalid remittance ID
    When I fetch remittance "NONEXISTENT"
    Then I should see error "Remittance not found"

  Scenario: Handle timeout when fetching remittances
    Given the Stedi API times out
    When I fetch remittances
    Then the fetch should fail gracefully
    And the error should be logged
