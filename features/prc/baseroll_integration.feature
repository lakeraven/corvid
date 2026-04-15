Feature: Baseroll demo adapter for enrollment verification
  As a PRC eligibility reviewer
  I need Baseroll enrollment data to auto-fill eligibility checklist items
  So that identity, enrollment, and residency documentation gaps are eliminated

  Background:
    Given a tenant "tnt_yakama" with facility "fac_toppenish"
    And the Baseroll demo adapter is active

  Scenario: Enrolled member's enrollment is verified
    When I verify tribal enrollment for the demo patient
    Then the enrollment result should show enrolled as true
    And the enrollment result should include a membership number
    And the enrollment result should include a tribe name

  Scenario: Enrolled member's identity documents are present
    When I verify identity documents for the demo patient
    Then the identity result should show ssn_present as true
    And the identity result should show dob_present as true

  Scenario: Enrolled member resides on reservation
    When I verify residency for the demo patient
    Then the residency result should show on_reservation as true
    And the residency result should include an address

  Scenario: Non-enrolled person is flagged
    When I verify tribal enrollment for a non-enrolled person
    Then the enrollment result should show enrolled as false

  Scenario: Off-reservation address is flagged
    When I verify residency for an off-reservation person
    Then the residency result should show on_reservation as false
