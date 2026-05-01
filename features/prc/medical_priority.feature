# frozen_string_literal: true

Feature: Medical priority assignment
  As a clinical reviewer
  I want referrals to be assigned a medical priority
  So that care is allocated according to funding priority guidelines

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And a patient "pt_mp_001" with a PRC case
    And a PRC referral "rf_mp_001" for that case

  # =============================================================================
  # PRIORITY ASSIGNMENT (corvid_v1: emergent/urgent/routine)
  # =============================================================================

  Scenario: Auto-assign Priority 1 for emergent care
    Given the service request urgency is "EMERGENT"
    When medical priority is assigned
    Then the priority level should be 1
    And the priority system should be "corvid_v1"
    And the priority name should include "Essential"

  Scenario: Auto-assign Priority 2 for urgent care
    Given the service request urgency is "URGENT"
    When medical priority is assigned
    Then the priority level should be 2
    And the priority name should include "Urgent"

  Scenario: Auto-assign Priority 3 for routine care
    Given the service request urgency is "ROUTINE"
    When medical priority is assigned
    Then the priority level should be 3
    And the priority name should include "Routine"

  Scenario: Defaults to corvid_v1 system
    Given the service request urgency is "ROUTINE"
    When medical priority is assigned
    Then the priority system should be "corvid_v1"

  # =============================================================================
  # FUNDING PRIORITY SCORES
  # =============================================================================

  Scenario: Emergent has highest funding score
    Given the service request urgency is "EMERGENT"
    When medical priority is assessed
    Then the funding score should be 100

  Scenario: Urgent has medium funding score
    Given the service request urgency is "URGENT"
    When medical priority is assessed
    Then the funding score should be 75

  Scenario: Routine has lowest funding score
    Given the service request urgency is "ROUTINE"
    When medical priority is assessed
    Then the funding score should be 50

  # =============================================================================
  # PRIORITY PREDICATES
  # =============================================================================

  Scenario: Emergent is essential but not necessary
    Given the service request urgency is "EMERGENT"
    When medical priority is assessed
    Then the result should be essential
    And the result should not be necessary

  Scenario: Urgent is necessary but not essential
    Given the service request urgency is "URGENT"
    When medical priority is assessed
    Then the result should be necessary
    And the result should not be essential

  Scenario: Routine is neither essential nor necessary
    Given the service request urgency is "ROUTINE"
    When medical priority is assessed
    Then the result should not be essential
    And the result should not be necessary

  # =============================================================================
  # REFERRAL RECORD UPDATES
  # =============================================================================

  Scenario: Priority assignment updates the referral record
    Given the service request urgency is "EMERGENT"
    When medical priority is assigned
    Then the referral should have medical priority set
    And the referral priority system should be "corvid_v1"

  # =============================================================================
  # EDGE CASES
  # =============================================================================

  Scenario: No service request returns unknown
    When medical priority is assigned without a service request
    Then the priority should be unknown

  Scenario: Nil urgency defaults to routine
    Given the service request urgency is nil
    When medical priority is assessed
    Then the priority level should be 3
