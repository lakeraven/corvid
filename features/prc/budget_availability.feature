# frozen_string_literal: true

Feature: Budget Availability
  As a PRC coordinator
  I want to verify CHS budget availability for referrals
  So that funds are allocated according to IHS payer-of-last-resort rules

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And a patient "pt_budget_001" with a PRC case
    And a PRC referral "rf_budget_001" for that case

  # =============================================================================
  # CHS FUND AVAILABILITY
  # =============================================================================

  Scenario: CHS referral approved when funds available
    Given the referral estimated cost is "$10,000"
    When I check budget availability
    Then funds should be available
    And the referral should be budget compliant

  Scenario: CHS referral denied when funds exhausted
    Given the referral estimated cost is "$1,500,000"
    When I check budget availability
    Then funds should not be available
    And the referral should not be budget compliant

  # =============================================================================
  # COST ESTIMATE REQUIREMENTS
  # =============================================================================

  Scenario: Cost estimate required for CHS funding
    Given no cost estimate is provided
    When I check budget availability
    Then a cost estimate should be required
    And the referral should not be budget compliant

  Scenario: Zero cost requires cost estimate
    Given the referral estimated cost is "$0"
    When I check budget availability
    Then a cost estimate should be required

  # =============================================================================
  # COMMITTEE REVIEW
  # =============================================================================

  Scenario: High-cost referral triggers committee review
    Given the referral estimated cost is "$60,000"
    When I check budget availability
    Then budget committee review should be required

  Scenario: Below-threshold referral does not require committee review
    Given the referral estimated cost is "$30,000"
    When I check budget availability
    Then budget committee review should not be required

  Scenario: Cost at exactly threshold requires committee review
    Given the referral estimated cost is "$50,000"
    When I check budget availability
    Then budget committee review should be required

  Scenario: Cost just below threshold does not require committee review
    Given the referral estimated cost is "$49,999"
    When I check budget availability
    Then budget committee review should not be required

  # =============================================================================
  # FISCAL YEAR
  # =============================================================================

  Scenario: Fiscal year uses October start
    Given the referral estimated cost is "$5,000"
    When I check budget availability
    Then the fiscal year should use October start

  # =============================================================================
  # BUDGET CHECK RESULT STRUCTURE
  # =============================================================================

  Scenario: Budget check result includes total budget
    Given the referral estimated cost is "$5,000"
    When I check budget availability
    Then the budget check result should have a positive total budget

  Scenario: Budget check result reports valid funding source
    Given the referral estimated cost is "$5,000"
    When I check budget availability
    Then the funding source should be valid

  # =============================================================================
  # FUND RESERVATION
  # =============================================================================

  Scenario: Reserve funds for a referral
    Given the referral estimated cost is "$10,000"
    When I reserve funds for the referral
    Then the reservation should be successful
