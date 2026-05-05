Feature: Program registry extensibility
  As a host application integrator
  I need to register custom programs without forking the engine
  So that I can support CMMI, state Medicaid, and other programs Corvid does not ship with

  Background:
    Given a tenant "tnt_reg_test" with facility "fac_reg_test"

  Scenario: Built-in IHS programs are registered out of the box
    Then the program registry should include "tb"
    And the program registry should include "hep_b"
    And the program registry should include "immunization"

  Scenario: Host registers a new program with milestones
    Given the host registers program "access_bh" with milestones:
      | key                | description       | days_after_anchor | required |
      | initial_phq9       | Initial PHQ-9     | 0                 | true     |
      | followup_phq9_30d  | 30-day PHQ-9      | 30                | true     |
    When I create an "access_bh" case for patient "pt_access_001" anchored on "2026-03-01"
    Then a program case should exist for patient "pt_access_001" with type "access_bh"
    And the case should have milestones "initial_phq9, followup_phq9_30d"

  Scenario: Validation rejects program codes that are not registered
    When I try to create a case with program type "totally_made_up"
    Then the case should be invalid with a program_type error
