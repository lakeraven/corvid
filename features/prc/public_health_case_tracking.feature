Feature: Public Health Case Tracking
  As a public health nurse
  I need program-specific case tracking with milestones
  So that I can manage patient follow-up and demonstrate compliance

  Background:
    Given a tenant "tnt_test" with facility "fac_test"

  Scenario: Create a case from a program template
    When I create a TB case for patient "12345" anchored on "2026-03-01"
    Then a program case should exist for patient "12345" with type "tb"
    And the case should have milestones from the TB template

  Scenario: Complete milestones in a Hep B perinatal case
    Given a Hep B perinatal case exists for infant "1001" with mother "2001" born "2026-03-01"
    When I record HBIG administration by provider "101"
    Then the "hbig_administration" milestone should be completed

  Scenario: Detect overdue milestones
    Given a Hep B perinatal case exists for infant "1001" with mother "2001" born "2025-01-01"
    Then the case should have overdue milestones

  Scenario: Close a case when all required milestones are complete
    Given a Hep B perinatal case exists for infant "1001" with mother "2001" born "2026-03-01"
    When all required milestones are completed
    And I try to close the case
    Then the case lifecycle status should be "closed"

  Scenario: View audit timeline for a case
    Given a Hep B perinatal case exists for infant "1001" with mother "2001" born "2026-03-01"
    When I request the audit timeline
    Then I should receive an ordered list of milestone entries
