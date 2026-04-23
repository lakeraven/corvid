Feature: Medical priority assignment
  As a PRC coordinator
  I want to automatically classify medical priority for referrals
  So that CHS funds are allocated by clinical need

  Background:
    Given a tenant "tnt_priority" with facility "fac_test"

  # =============================================================================
  # IHS 2024 PRIORITY SYSTEM
  # =============================================================================

  Scenario: Priority 1 Essential for life-threatening emergency
    Given a service request with urgency "EMERGENT"
    And the reason for referral is "Severe chest pain, suspected myocardial infarction, life-threatening"
    When I assess medical priority using "ihs_2024"
    Then the priority level should be 1
    And the priority name should include "Essential"
    And it should not require clinical review

  Scenario: Priority 2 Necessary for chronic disease management
    Given a service request with urgency "ROUTINE"
    And the reason for referral is "Chronic diabetes management, follow-up care"
    When I assess medical priority using "ihs_2024"
    Then the priority level should be 2
    And the priority name should include "Necessary"

  Scenario: Priority 3 Justifiable for preventive care
    Given a service request with urgency "ROUTINE"
    And the reason for referral is "Annual screening mammogram, preventive care"
    When I assess medical priority using "ihs_2024"
    Then the priority level should be 3
    And the priority name should include "Justifiable"

  Scenario: Priority 4 Excluded for cosmetic procedures
    Given a service request with urgency "ROUTINE"
    And the reason for referral is "Cosmetic rhinoplasty, not covered"
    When I assess medical priority using "ihs_2024"
    Then the priority level should be 4
    And the priority name should include "Excluded"

  Scenario: Defaults to Justifiable when no keywords match
    Given a service request with urgency "ROUTINE"
    And the reason for referral is "General evaluation needed"
    When I assess medical priority using "ihs_2024"
    Then the priority level should be 3
    And it should require clinical review

  # =============================================================================
  # FUNDING PRIORITY SCORING
  # =============================================================================

  Scenario: Essential has highest funding score
    Given a service request with urgency "EMERGENT"
    And the reason for referral is "Life-threatening emergency"
    When I assess medical priority using "ihs_2024"
    Then the funding priority score should be 100

  Scenario: Excluded has zero funding score
    Given a service request with urgency "ROUTINE"
    And the reason for referral is "Cosmetic procedure, not covered"
    When I assess medical priority using "ihs_2024"
    Then the funding priority score should be 0

  # =============================================================================
  # SIMPLE ASSIGN
  # =============================================================================

  Scenario: Assigns emergent priority to referral
    Given a PRC referral with an emergent service request
    When I assign medical priority
    Then the referral medical priority should be 1

  Scenario: Assigns urgent priority to referral
    Given a PRC referral with an urgent service request
    When I assign medical priority
    Then the referral medical priority should be 2

  Scenario: Assigns routine priority by default
    Given a PRC referral with a routine service request
    When I assign medical priority
    Then the referral medical priority should be 3

  Scenario: Returns unknown when no service request
    Given a PRC referral with no service request
    When I assign medical priority
    Then the result should be "unknown"

  Scenario: Sets priority system to corvid_v1
    Given a PRC referral with a routine service request
    When I assign medical priority
    Then the referral priority system should be "corvid_v1"

  Scenario: Assessment includes all data in hash
    Given a service request with urgency "EMERGENT"
    And the reason for referral is "Life-threatening cardiac emergency"
    When I assess medical priority using "ihs_2024"
    Then the assessment hash should include priority_level 1
    And the assessment hash should include priority_system "ihs_2024"
    And the assessment hash should include funding_score 100
