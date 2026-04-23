Feature: Budget Availability
  As a PRC coordinator
  I want to verify CHS budget availability for referrals
  So that funds are allocated according to IHS payer-of-last-resort rules

  Background:
    Given a tenant "tnt_budget" with facility "fac_test"

  # =============================================================================
  # CHS FUND AVAILABILITY
  # =============================================================================

  Scenario: CHS referral approved when funds available
    Given a PRC referral with estimated cost "$10,000"
    When I check budget availability
    Then funds should be available

  Scenario: CHS referral denied when funds exhausted
    Given a PRC referral with estimated cost "$1,500,000"
    When I check budget availability
    Then funds should not be available

  # =============================================================================
  # COMMITTEE REVIEW THRESHOLD
  # =============================================================================

  Scenario: High-cost referral triggers committee review
    Given a PRC referral with estimated cost "$60,000"
    When I check if committee review is required
    Then committee review should be required

  Scenario: Below-threshold referral does not require committee review
    Given a PRC referral with estimated cost "$30,000"
    When I check if committee review is required
    Then committee review should not be required

  # =============================================================================
  # FISCAL YEAR
  # =============================================================================

  Scenario: Current quarter uses federal fiscal year
    When I check the current quarter
    Then the quarter should match a fiscal year format

  Scenario: October is Q1 of next fiscal year
    Given the date is October 15
    When I check the current quarter
    Then the quarter should include "Q1"

  # =============================================================================
  # BUDGET DEFAULTS
  # =============================================================================

  Scenario: Default budget when adapter returns nil
    Given no budget data is configured
    When I check the fiscal year budget
    Then the budget should default to "$1,000,000"

  Scenario: Committee review threshold is $50,000
    When I check the committee review threshold
    Then the threshold should be "$50,000"
