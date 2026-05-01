# frozen_string_literal: true

Feature: PRC Review Committee
  As a PRC manager
  I want committee reviews for high-cost or flagged referrals
  So that authorization decisions follow IHS fiscal oversight rules

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And a patient "pt_comm_001" with a PRC case
    And a PRC referral "rf_comm_001" for that case

  # =============================================================================
  # COMMITTEE REVIEW REQUIREMENTS
  # =============================================================================

  Scenario: High-cost referral requires committee review
    Given the referral estimated cost is "$75,000"
    Then the referral should require committee review

  Scenario: Low-cost referral does not require committee review
    Given the referral estimated cost is "$25,000"
    Then the referral should not require committee review

  Scenario: Priority 3 or higher requires committee review
    Given the referral has medical priority 3
    And the referral estimated cost is "$10,000"
    Then the referral should require committee review

  # =============================================================================
  # COMMITTEE SCHEDULING & DECISIONS
  # =============================================================================

  Scenario: Schedule committee review
    When I schedule a committee review for "2026-06-15"
    Then a committee review should exist
    And the committee date should be "2026-06-15"
    And the committee decision should be "pending"

  Scenario: Committee approves referral
    Given a pending committee review for "2026-06-15"
    When the committee approves with amount 75000 by reviewer "pr_101"
    Then the committee decision should be "approved"
    And the approved amount should be 75000

  Scenario: Committee denies referral
    Given a pending committee review for "2026-06-15"
    When the committee denies with rationale "Not medically necessary" by reviewer "pr_101"
    Then the committee decision should be "denied"
    And the appeal deadline should be set

  Scenario: Committee defers decision
    Given a pending committee review for "2026-06-15"
    When the committee defers with rationale "Awaiting Medicare enrollment" by reviewer "pr_101"
    Then the committee decision should be "deferred"

  Scenario: Committee modifies and approves
    Given a pending committee review for "2026-06-15"
    When the committee modifies with approved amount 75000 from requested 100000 by reviewer "pr_101"
    Then the committee decision should be "modified"
    And the approved amount should be 75000

  # =============================================================================
  # COMMITTEE DOCUMENTATION
  # =============================================================================

  Scenario: Add attendees to committee review
    Given a pending committee review for "2026-06-15"
    When I add 3 attendees to the committee review
    Then the review should have 3 attendees

  Scenario: Add documents reviewed
    Given a pending committee review for "2026-06-15"
    When I add 2 documents to the committee review
    Then the review should have 2 documents reviewed

  Scenario: Add conditions for approval
    Given a pending committee review for "2026-06-15"
    When I add 2 conditions to the committee review
    And the committee approves with amount 75000 by reviewer "pr_101"
    Then the review should have 2 conditions

  # =============================================================================
  # COMMITTEE VIEWS
  # =============================================================================

  Scenario: View upcoming committee reviews
    Given committee reviews scheduled for tomorrow and next week and next month
    When I view upcoming committee reviews for the next 7 days
    Then I should see 2 upcoming reviews

  # =============================================================================
  # DECISION APPLICATION
  # =============================================================================

  Scenario: Approved decision applies to referral
    Given a referral in committee review state
    And a pending committee review for "2026-06-15"
    When the committee approves with amount 75000 by reviewer "pr_101"
    And the decision is applied to the referral
    Then the referral should be authorized

  Scenario: Denied decision applies to referral
    Given a referral in committee review state
    And a pending committee review for "2026-06-15"
    When the committee denies with rationale "Not medically necessary" by reviewer "pr_101"
    And the decision is applied to the referral
    Then the referral should be denied
