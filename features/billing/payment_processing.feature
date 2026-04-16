@payments @ulster-rfp
Feature: Payment Processing
  As a billing staff member
  I want to accept credit and debit card payments from patients
  So that patients can pay copays and balances at point of service

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And the billing adapter is configured
    And Stripe is configured for payment processing

  # =============================================================================
  # PAYMENT CREATION
  # =============================================================================

  Scenario: Create a payment for a patient copay
    Given a patient "DOE,JOHN" with DFN "1" exists
    When I create a payment for patient "1" with amount "$50.00"
    Then a payment record should be created with status "pending"
    And the payment amount should be 5000 cents

  Scenario: Create a payment linked to a service request
    Given a patient "DOE,JOHN" with DFN "1" exists
    And a service request "2025-00200" exists for patient "1"
    When I create a payment for patient "1" with amount "$150.00" for service request "2025-00200"
    Then the payment should be linked to service request "2025-00200"

  # =============================================================================
  # STRIPE INTEGRATION
  # =============================================================================

  Scenario: Process a card payment via Stripe
    Given a pending payment of "$75.00" exists for patient "1"
    When I submit the payment to Stripe
    Then a Stripe PaymentIntent should be created
    And the payment status should be "processing"

  Scenario: Payment succeeds after card authorization
    Given a processing payment exists with Stripe ID "pi_test_success"
    When Stripe confirms the payment succeeded
    Then the payment status should be "succeeded"
    And a receipt URL should be recorded

  Scenario: Payment fails due to card decline
    Given a pending payment of "$75.00" exists for patient "1"
    When I submit the payment to Stripe and the card is declined
    Then the payment status should be "failed"
    And the error message should indicate "Card declined"

  # =============================================================================
  # REFUNDS
  # =============================================================================

  Scenario: Refund a completed payment
    Given a succeeded payment of "$75.00" exists with Stripe ID "pi_test_refund"
    When I refund the payment
    Then the payment status should be "refunded"

  Scenario: Cannot refund a pending payment
    Given a pending payment of "$75.00" exists for patient "1"
    When I attempt to refund the payment
    Then the refund should fail with "Payment not refundable"

  # =============================================================================
  # REPORTING
  # =============================================================================

  Scenario: View total collected payments for a patient
    Given the following payments exist for patient "1":
      | amount  | status    |
      | $50.00  | succeeded |
      | $75.00  | succeeded |
      | $25.00  | failed    |
    Then the total collected for patient "1" should be "$125.00"
