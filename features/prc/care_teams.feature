Feature: Integrated care teams
  As a care coordinator
  I want to manage integrated care teams
  So that patients have relationship-based care

  Background:
    Given a tenant "tnt_test" with facility "fac_test"

  # =============================================================================
  # CARE TEAM CREATION
  # =============================================================================

  Scenario: Create a care team
    When I create a care team named "Blue Team"
    Then a care team "Blue Team" should exist
    And it should belong to facility "fac_test"

  Scenario: Care team requires a name
    When I try to create a care team without a name
    Then the care team should be invalid
    And there should be an error on "name"

  Scenario: Care team can have a description
    When I create a care team named "Red Team" with description "Pediatric focused care team"
    Then the care team "Red Team" should have description "Pediatric focused care team"

  # =============================================================================
  # CARE TEAM MEMBERSHIP
  # =============================================================================

  Scenario: Add members to care team
    Given a care team "Blue Team" exists
    When I add a member with role "Primary Care Provider" and practitioner IEN "101"
    And I add a member with role "Care Manager" and practitioner IEN "102"
    And I add a member with role "Behavioral Health" and practitioner IEN "103"
    Then "Blue Team" should have 3 members

  Scenario: Care team member requires role
    Given a care team "Blue Team" exists
    When I try to add a member without a role
    Then the member should be invalid
    And there should be an error on member "role"

  Scenario: Remove member from care team
    Given a care team "Blue Team" exists
    And the care team has a member with role "Primary Care Provider" and practitioner IEN "101"
    When I remove the member with practitioner IEN "101"
    Then "Blue Team" should have 0 members

  Scenario: Member can have a start and end date
    Given a care team "Blue Team" exists
    When I add a member with role "Consultant" and practitioner IEN "105" starting "2024-01-01"
    Then the member should have start date "2024-01-01"
    And the member should be active

  Scenario: Member with end date is inactive
    Given a care team "Blue Team" exists
    And the care team has a member with role "Former PCP" ending "2023-12-31"
    Then the member should be inactive
    And "Blue Team" should have 0 active members

  # =============================================================================
  # CASE ASSIGNMENT
  # =============================================================================

  Scenario: Assign case to care team
    Given a care team "Blue Team" exists
    And a case exists for patient "Mary Jones"
    When I assign the case to care team "Blue Team"
    Then the case care team should be "Blue Team"

  Scenario: Care team sees assigned cases
    Given a care team "Blue Team" exists
    And a case exists for patient "Mary Jones" assigned to "Blue Team"
    And a case exists for patient "John Smith" assigned to "Blue Team"
    When I view cases for care team "Blue Team"
    Then I should see 2 cases

  Scenario: Unassigned case has no care team
    Given a case exists for patient "Orphan Patient"
    Then the case should have no care team

  # =============================================================================
  # TEAM LEAD AND ROLES
  # =============================================================================

  Scenario: Care team can have a lead
    Given a care team "Blue Team" exists
    When I add a member with role "Team Lead" and practitioner IEN "101" as lead
    Then "Blue Team" should have a lead
    And the lead should have practitioner IEN "101"

  Scenario: Only one lead per care team
    Given a care team "Blue Team" exists
    And the care team has a lead with practitioner IEN "101"
    When I add a member with role "Team Lead" and practitioner IEN "102" as lead
    Then the lead should have practitioner IEN "102"
    And the former lead should still be a member

  # =============================================================================
  # CARE TEAM SCOPES
  # =============================================================================

  Scenario: Find active care teams
    Given an active care team "Active Team" exists
    And an inactive care team "Inactive Team" exists
    When I view active care teams
    Then I should see care team "Active Team"
    And I should not see care team "Inactive Team"

  @wip
  Scenario: Care teams are facility-scoped
    Given a facility "fac_other" with code "CHN" exists
    And a care team "Blue Team" exists at facility "fac_test"
    And a care team "Red Team" exists at facility "fac_other"
    When I am working at facility "fac_test"
    And I view all care teams
    Then I should see care team "Blue Team"
    And I should not see care team "Red Team"

  # =============================================================================
  # FHIR SERIALIZATION
  # =============================================================================

  Scenario: FHIR CareTeam resource
    Given a care team "Blue Team" exists
    And the care team has the following members:
      | role                   | practitioner_ien |
      | Primary Care Provider  | 101              |
      | Care Manager           | 102              |
      | Behavioral Health      | 103              |
    When I request the FHIR representation
    Then I should receive a valid FHIR CareTeam resource
    And the FHIR resource should have 3 participants
    And the FHIR resource should have status "active"

  Scenario: FHIR CareTeam includes managing organization
    Given a care team "Blue Team" exists
    When I request the FHIR representation
    Then the FHIR resource should reference the facility as managing organization

  # =============================================================================
  # TEAM-BASED TASK ROUTING
  # =============================================================================

  Scenario: Create task for care team
    Given a care team "Blue Team" exists
    And a case exists for patient "Mary Jones" assigned to "Blue Team"
    When I create a task "Follow up with patient" for the case
    Then the task should be visible to all "Blue Team" members

  Scenario: Task can be assigned to care team member
    Given a care team "Blue Team" exists
    And the care team has a member with role "Care Manager" and practitioner IEN "102"
    And a case exists for patient "Mary Jones" assigned to "Blue Team"
    When I create a task "Schedule follow-up" assigned to practitioner "102"
    Then the task assignee should be practitioner "102"
