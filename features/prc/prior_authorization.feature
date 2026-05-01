# frozen_string_literal: true

Feature: Prior Authorization
  As a PRC coordinator
  I want to ensure proper authorization is obtained for referrals
  So that services comply with IHS prior authorization requirements

  Background:
    Given a tenant "tnt_test" with facility "fac_test"

  # =============================================================================
  # EMERGENCY REFERRALS (72-hour notification window)
  # =============================================================================

  Scenario: Emergency services exempt from prior authorization
    Given a service request with urgency "EMERGENT"
    When I check prior authorization requirements
    Then the authorization type should be "emergency"
    And prior authorization should not be required

  Scenario: Emergency referral within 72-hour notification window
    Given a service request with urgency "EMERGENT"
    And the service was requested today
    When I check prior authorization requirements
    Then the referral should be within the notification window
    And retroactive authorization should not be required

  Scenario: Emergency referral beyond 72-hour window needs retroactive auth
    Given a service request with urgency "EMERGENT"
    And the service was requested 5 days ago
    When I check prior authorization requirements
    Then the referral should not be within the notification window
    And retroactive authorization should be required

  Scenario: Emergency notification deadline is calculated correctly
    Given a service request with urgency "EMERGENT"
    And the service was requested today
    When I check prior authorization requirements
    Then the notification deadline should be 3 days from today

  # =============================================================================
  # NON-EMERGENCY (ROUTINE) REFERRALS
  # =============================================================================

  Scenario: Routine service requiring prior auth is flagged
    Given a service request with urgency "ROUTINE"
    And the service requires authorization
    When I check prior authorization requirements
    Then the authorization type should be "prior"
    And prior authorization should be required

  Scenario: Routine service not requiring auth passes
    Given a service request with urgency "ROUTINE"
    And the service does not require authorization
    When I check prior authorization requirements
    Then prior authorization should not be required
    And the referral should be compliant

  Scenario: Missing authorization reason blocks compliance
    Given a service request with urgency "ROUTINE"
    And the service requires authorization
    And no authorization reason is documented
    When I check prior authorization requirements
    Then the referral should not be compliant

  # =============================================================================
  # HIGH-COST REFERRALS (Committee Review)
  # =============================================================================

  Scenario: High-cost referral requires committee review
    Given a service request with estimated cost "$60,000"
    When I check prior authorization requirements
    Then committee review should be required
    And the authorization reason should mention "cost threshold"

  Scenario: Cost below threshold does not require committee review
    Given a service request with estimated cost "$30,000"
    When I check prior authorization requirements
    Then committee review should not be required

  Scenario: Explicit committee review flag overrides cost check
    Given a service request with estimated cost "$10,000"
    And the service request requires committee review
    When I check prior authorization requirements
    Then committee review should be required

  Scenario: High-cost referral needs case manager
    Given a service request with estimated cost "$60,000"
    And no case manager is assigned
    When I check prior authorization requirements
    Then a case manager should be required
    And the referral should not be compliant

  Scenario: High-cost referral with case manager is compliant
    Given a service request with estimated cost "$60,000"
    And a case manager is assigned
    When I check prior authorization requirements
    Then the referral should be compliant
