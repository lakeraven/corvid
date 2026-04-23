Feature: Task FHIR resource
  As a PRC coordinator
  I need workflow tasks to be FHIR-compliant
  So I can coordinate care activities across systems

  Background:
    Given a tenant "tnt_fhir_task" with facility "fac_test"

  # =============================================================================
  # TASK STATUS MAPPING
  # =============================================================================

  Scenario: Pending task maps to requested status
    Given a task exists with status "pending"
    When I serialize the task to FHIR
    Then the FHIR task status should be "requested"

  Scenario: In progress task maps to in-progress status
    Given a task exists with status "in_progress"
    When I serialize the task to FHIR
    Then the FHIR task status should be "in-progress"

  Scenario: Completed task maps to completed status
    Given a task exists with status "completed"
    When I serialize the task to FHIR
    Then the FHIR task status should be "completed"

  Scenario: Cancelled task maps to cancelled status
    Given a task exists with status "cancelled"
    When I serialize the task to FHIR
    Then the FHIR task status should be "cancelled"

  Scenario: On hold task maps to on-hold status
    Given a task exists with status "on_hold"
    When I serialize the task to FHIR
    Then the FHIR task status should be "on-hold"

  # =============================================================================
  # FHIR SERIALIZATION
  # =============================================================================

  Scenario: FHIR Task has correct resourceType
    Given a task exists with status "pending"
    When I serialize the task to FHIR
    Then the FHIR resourceType should be "Task"

  Scenario: FHIR Task includes intent
    Given a task exists with status "pending"
    When I serialize the task to FHIR
    Then the FHIR task intent should be "order"

  Scenario: FHIR Task includes priority
    Given an urgent task exists
    When I serialize the task to FHIR
    Then the FHIR task priority should be "urgent"

  Scenario: FHIR Task includes description
    Given a task exists with description "Follow up on lab results"
    When I serialize the task to FHIR
    Then the FHIR task description should be "Follow up on lab results"

  Scenario: FHIR Task includes focus for Case
    Given a task exists on a case
    When I serialize the task to FHIR
    Then the FHIR task focus should reference "EpisodeOfCare"

  Scenario: FHIR Task includes focus for PrcReferral
    Given a task exists on a referral
    When I serialize the task to FHIR
    Then the FHIR task focus should reference "ServiceRequest"

  Scenario: FHIR Task includes owner when assigned
    Given a task exists assigned to "pr_001"
    When I serialize the task to FHIR
    Then the FHIR task owner should reference "Practitioner/pr_001"

  Scenario: FHIR Task omits owner when unassigned
    Given a task exists with status "pending"
    When I serialize the task to FHIR
    Then the FHIR task should have no owner

  Scenario: FHIR Task includes executionPeriod when due
    Given a task exists due in 3 days
    When I serialize the task to FHIR
    Then the FHIR task should have executionPeriod

  Scenario: FHIR Task omits executionPeriod when no due date
    Given a task exists with status "pending"
    When I serialize the task to FHIR
    Then the FHIR task should not have executionPeriod

  Scenario: FHIR Task includes timestamps
    Given a task exists with status "pending"
    When I serialize the task to FHIR
    Then the FHIR task should have authoredOn
    And the FHIR task should have lastModified

  # =============================================================================
  # FHIR ROUND-TRIP
  # =============================================================================

  Scenario: Round-trip preserves status for all values
    Given tasks exist with all five statuses
    When I serialize and parse each task
    Then each round-trip should preserve the original status
