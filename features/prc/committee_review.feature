Feature: PRC Review Committee
  As a PRC Review Committee member
  I want to review high-cost and complex referrals
  So that authorization decisions are properly vetted

  Background:
    Given a tenant "tnt_committee" with facility "fac_test"
    And a case exists for patient "pt_committee"
    And a PRC referral exists with estimated cost "$75,000"

  # =============================================================================
  # COMMITTEE REVIEW TRIGGERS
  # =============================================================================

  Scenario: High-cost referral requires committee review
    Given the referral estimated cost is "$60,000"
    When I check if committee review is required
    Then committee review should be required

  Scenario: Low-cost referral does not require committee review
    Given the referral estimated cost is "$25,000"
    When I check if committee review is required
    Then committee review should not be required

  Scenario: Priority 3 or higher requires committee review
    Given the referral has medical priority 3
    And the referral estimated cost is "$10,000"
    When I check if committee review is required
    Then committee review should be required

  Scenario: Flagged referral requires committee review
    Given the referral is flagged for review
    And the referral estimated cost is "$10,000"
    When I check if committee review is required
    Then committee review should be required

  # =============================================================================
  # COMMITTEE DECISIONS
  # =============================================================================

  Scenario: Schedule committee review
    When I schedule a committee review for today
    Then a committee review should exist
    And the review decision should be "pending"

  Scenario: Committee approves referral
    Given a pending committee review exists
    When the committee approves with amount "$75,000"
    Then the review decision should be "approved"

  Scenario: Committee denies referral
    Given a pending committee review exists
    When the committee denies the referral
    Then the review decision should be "denied"

  Scenario: Committee defers decision
    Given a pending committee review exists
    When the committee defers the decision
    Then the review decision should be "deferred"

  Scenario: Committee modifies and approves
    Given a pending committee review exists
    When the committee modifies with amount "$75,000"
    Then the review decision should be "modified"

  # =============================================================================
  # FINALIZED PREDICATE
  # =============================================================================

  Scenario: Pending review is not finalized
    Given a pending committee review exists
    Then the review should not be finalized

  Scenario: Approved review is finalized
    Given a pending committee review exists
    When the committee approves with amount "$75,000"
    Then the review should be finalized

  Scenario: Denied review is finalized
    Given a pending committee review exists
    When the committee denies the referral
    Then the review should be finalized

  # =============================================================================
  # APPLY TO REFERRAL
  # =============================================================================

  Scenario: Applying approved review authorizes referral
    Given the referral is in committee_review state
    And a pending committee review exists
    When the committee approves with amount "$75,000"
    And I apply the review to the referral
    Then the PRC referral status should be "authorized"

  Scenario: Applying denied review denies referral
    Given the referral is in committee_review state
    And a pending committee review exists
    When the committee denies the referral
    And I apply the review to the referral
    Then the PRC referral status should be "denied"

  Scenario: Applying deferred review defers referral
    Given the referral is in committee_review state
    And a pending committee review exists
    When the committee defers the decision
    And I apply the review to the referral
    Then the PRC referral status should be "deferred"

  # =============================================================================
  # SYNC TO EHR
  # =============================================================================

  Scenario: Approved decision syncs to EHR
    Given a pending committee review exists
    And the referral is registered with the adapter
    When the committee approves with amount "$75,000"
    And the decision is synced to EHR
    Then the sync should be successful

  Scenario: Pending decision does not sync
    Given a pending committee review exists
    When I attempt to sync the pending decision to EHR
    Then the sync should fail with "pending"
