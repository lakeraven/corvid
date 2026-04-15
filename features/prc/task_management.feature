Feature: Task Management
  As a care coordinator
  I want to manage tasks for cases and referrals
  So that work items are tracked and assigned

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And a patient "pt_001" with a PRC case

  # =============================================================================
  # TASK LIFECYCLE
  # =============================================================================

  Scenario: Create a task for a case
    When I create a task with description "Follow up on referral"
    Then a task should exist with description "Follow up on referral"
    And the task status should be "pending"

  Scenario: Task requires a description
    When I try to create a task without a description
    Then the task should be invalid
    And I should see an error about description

  Scenario: Start working on a task
    Given a pending task exists
    When I start the task
    Then the task status should be "in_progress"

  Scenario: Complete a task
    Given a task in progress exists
    When I complete the task
    Then the task status should be "completed"
    And the task should have a completed_at timestamp

  Scenario: Cancel a task
    Given a pending task exists
    When I cancel the task
    Then the task status should be "cancelled"

  Scenario: Put a task on hold
    Given a task in progress exists
    When I put the task on hold
    Then the task status should be "on_hold"

  # =============================================================================
  # TASK ASSIGNMENT
  # =============================================================================

  Scenario: Assign a task to a practitioner
    Given a pending task exists
    When I assign the task to practitioner "pr_101"
    Then the task should be assigned to practitioner "pr_101"

  Scenario: Unassign a task
    Given a task assigned to practitioner "pr_101" exists
    When I unassign the task
    Then the task should be unassigned

  # =============================================================================
  # TASK PRIORITY
  # =============================================================================

  Scenario: Create a routine priority task
    When I create a task with priority "routine"
    Then the task priority should be "routine"

  Scenario: Create an urgent priority task
    When I create a task with priority "urgent"
    Then the task priority should be "urgent"

  Scenario: Create a STAT priority task
    When I create a task with priority "stat"
    Then the task priority should be "stat"

  # =============================================================================
  # TASK DUE DATES AND OVERDUE
  # =============================================================================

  Scenario: Task with due date in the future is not overdue
    Given a task due in 3 days exists
    Then the task should not be overdue

  Scenario: Task with due date in the past is overdue
    Given a task due 2 days ago exists
    Then the task should be overdue

  Scenario: Completed task is not overdue
    Given a completed task due 2 days ago exists
    Then the task should not be overdue

  # =============================================================================
  # TASK SCOPES
  # =============================================================================

  Scenario: Find incomplete tasks
    Given the following tasks exist:
      | description | status     |
      | Task A      | pending    |
      | Task B      | in_progress|
      | Task C      | completed  |
      | Task D      | cancelled  |
    When I query for incomplete tasks
    Then I should see 2 incomplete tasks

  Scenario: Find overdue tasks
    Given a task due 5 days ago exists
    And a task due in 5 days exists
    When I query for overdue tasks
    Then I should see 1 overdue task

  Scenario: Find tasks due soon
    Given a task due in 3 days exists
    And a task due in 10 days exists
    When I query for tasks due within 7 days
    Then I should see 1 task due soon
