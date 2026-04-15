Feature: Enrollment verification via adapter
  As a PRC eligibility reviewer
  I need the system to verify tribal enrollment, identity, and residency via the adapter
  So that eligibility documentation is auto-populated instead of manually collected

  Background:
    Given a tenant "tnt_yakama" with facility "fac_toppenish"

  Scenario: Verify tribal enrollment for an enrolled patient
    Given a patient "pt_enrolled_001" registered in the adapter as enrolled
    When I verify tribal enrollment for "pt_enrolled_001"
    Then the enrollment result should show enrolled as true
    And the enrollment result should include a membership number
    And the enrollment result should include a tribe name

  Scenario: Verify tribal enrollment for a non-enrolled patient
    Given a patient "pt_nonenrolled_001" registered in the adapter as not enrolled
    When I verify tribal enrollment for "pt_nonenrolled_001"
    Then the enrollment result should show enrolled as false

  Scenario: Verify identity documents for a patient with full records
    Given a patient "pt_enrolled_001" registered in the adapter as enrolled
    When I verify identity documents for "pt_enrolled_001"
    Then the identity result should show ssn_present as true
    And the identity result should show dob_present as true

  Scenario: Verify residency for an on-reservation patient
    Given a patient "pt_enrolled_001" registered in the adapter with an on-reservation address
    When I verify residency for "pt_enrolled_001"
    Then the residency result should show on_reservation as true
    And the residency result should include an address

  Scenario: Verify residency for an off-reservation patient
    Given a patient "pt_off_res_001" registered in the adapter with an off-reservation address
    When I verify residency for "pt_off_res_001"
    Then the residency result should show on_reservation as false
