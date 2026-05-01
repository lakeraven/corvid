# frozen_string_literal: true

Feature: PRC Authorization Workflow (extended)
  As a PRC case manager
  I want full lifecycle tracking for PRC referrals
  So that authorization decisions, deferrals, and cancellations are auditable

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And a patient "pt_wf_001" with a PRC case
    And a PRC referral "rf_wf_001" for that case

  # =============================================================================
  # DEFERRAL
  # =============================================================================

  Scenario: Referral deferred from committee review
    Given a referral in committee review state
    When the referral is deferred
    Then the referral status should be "deferred"

  Scenario: Deferral records determination
    Given a referral in committee review state
    When the referral is deferred
    Then a determination should be recorded with outcome "deferred"

  # =============================================================================
  # CANCELLATION
  # =============================================================================

  Scenario: Draft referral can be cancelled
    When the referral is cancelled
    Then the referral status should be "cancelled"

  Scenario: Submitted referral can be cancelled
    Given the referral has been submitted
    When the referral is cancelled
    Then the referral status should be "cancelled"

  Scenario: Authorized referral can be cancelled
    Given a referral in committee review state
    And the referral has been authorized
    When the referral is cancelled
    Then the referral status should be "cancelled"

  # =============================================================================
  # AUTHORIZATION
  # =============================================================================

  Scenario: Referral authorized from priority assignment (no committee needed)
    Given the referral is in priority assignment with low cost
    When the referral is authorized
    Then the referral status should be "authorized"

  Scenario: High-cost referral routes to committee review
    Given the referral is in priority assignment with high cost
    When priority assignment completes
    Then the referral status should be "committee_review"

  # =============================================================================
  # DENIAL
  # =============================================================================

  Scenario: Referral denied from eligibility review
    Given the referral is in eligibility review
    When the referral is denied
    Then the referral status should be "denied"

  Scenario: Referral denied from committee review
    Given a referral in committee review state
    When the referral is denied
    Then the referral status should be "denied"
