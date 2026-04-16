Feature: 72-hour emergency notification
  As a care coordinator
  I want the system to enforce 72-hour notification rules
  So that emergency PRC referrals comply with IHS regulations

  Background:
    Given a tenant "tnt_test" with facility "fac_test"
    And a patient "pt_001" with a PRC case
    And a PRC referral "rf_notif_001" for that case

  # =============================================================================
  # TIMELY NOTIFICATION (WITHIN 72 HOURS)
  # =============================================================================

  Scenario: Emergency referral within 72 hours is timely
    Given the referral is flagged as emergency
    And the emergency occurred "48" hours ago
    When notification status is checked
    Then the notification should be "timely"
    And the referral should not require exception review

  Scenario: Emergency referral exactly at 72 hours is timely
    Given the referral is flagged as emergency
    And the emergency occurred "72" hours ago
    When notification status is checked
    Then the notification should be "timely"

  Scenario: Emergency referral at 71 hours is timely
    Given the referral is flagged as emergency
    And the emergency occurred "71" hours ago
    When notification status is checked
    Then the notification should be "timely"

  # =============================================================================
  # LATE NOTIFICATION (AFTER 72 HOURS)
  # =============================================================================

  Scenario: Emergency referral after 72 hours is late
    Given the referral is flagged as emergency
    And the emergency occurred "73" hours ago
    When notification status is checked
    Then the notification should be "late"
    And the referral should require exception review

  Scenario: Emergency referral significantly late
    Given the referral is flagged as emergency
    And the emergency occurred "120" hours ago
    When notification status is checked
    Then the notification should be "late"
    And the late notification hours should be "120"

  # =============================================================================
  # NON-EMERGENCY REFERRALS
  # =============================================================================

  Scenario: Non-emergency referral no notification required
    Given the referral is not flagged as emergency
    When notification status is checked
    Then the notification should be "not_required"
    And the referral should not require exception review

  Scenario: Non-emergency with notification date is still not required
    Given the referral is not flagged as emergency
    And the emergency occurred "100" hours ago
    When notification status is checked
    Then the notification should be "not_required"

  # =============================================================================
  # MISSING NOTIFICATION DATE
  # =============================================================================

  Scenario: Emergency referral without notification date
    Given the referral is flagged as emergency
    And the referral has no notification date
    When notification status is checked
    Then the notification should be "missing"
    And the referral should require exception review

  # =============================================================================
  # CONFIGURABLE GRACE PERIOD
  # =============================================================================

  Scenario: Facility can configure grace period
    Given the facility has a notification grace period of "96" hours
    And the referral is flagged as emergency
    And the emergency occurred "80" hours ago
    When notification status is checked
    Then the notification should be "timely"

  Scenario: Facility with shorter grace period
    Given the facility has a notification grace period of "48" hours
    And the referral is flagged as emergency
    And the emergency occurred "60" hours ago
    When notification status is checked
    Then the notification should be "late"

  # =============================================================================
  # EXCEPTION REVIEW WORKFLOW
  # =============================================================================

  Scenario: Late notification creates exception review task
    Given the referral is flagged as emergency
    And the emergency occurred "96" hours ago
    When the referral is submitted for exception review
    Then a task should be created for exception review
    And the task description should include "late notification"

  Scenario: Exception review can be approved
    Given the referral is flagged as emergency
    And the emergency occurred "96" hours ago
    And the late notification has been documented
    When exception review is approved with rationale "Unavoidable delay due to remote location"
    Then the referral should proceed to eligibility review
    And the exception approval should be recorded

  Scenario: Exception review can be denied
    Given the referral is flagged as emergency
    And the emergency occurred "200" hours ago
    And the late notification has been documented
    When exception review is denied with rationale "Excessive delay without justification"
    Then the referral should be denied
    And the denial reason should include "notification requirements"

  # =============================================================================
  # DOCUMENTATION REQUIREMENTS
  # =============================================================================

  Scenario: Late notification must be documented
    Given the referral is flagged as emergency
    And the emergency occurred "80" hours ago
    When late notification is documented with reason "Patient was stabilized at remote facility before transport"
    Then the late notification reason should be recorded
    And the documentation timestamp should be recorded
