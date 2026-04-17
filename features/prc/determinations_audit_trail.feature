Feature: Eligibility determination audit trail
  As a compliance officer
  I want to see a complete history of eligibility decisions
  So that I can audit PRC authorizations

  Background:
    Given a tenant "tnt_test" with facility "fac_test"

  Scenario: Record automated eligibility determination
    Given a case exists for patient "Jane Doe"
    When the system performs an automated eligibility check
    And the patient is found eligible
    Then a determination should be recorded
    And the determination decision_method should be "automated"
    And the determination outcome should be "approved"
    And the determination should include reasoning

  Scenario: Record committee review determination
    Given a case exists for patient "Jane Doe"
    And a PRC referral exists with estimated cost "$75000"
    When the PRC Review Committee approves the referral
    Then a determination should be recorded
    And the determination decision_method should be "committee_review"
    And the determination should include the reviewer ID

  Scenario: View determination history
    Given a case exists for patient "Jane Doe"
    And the case has 3 determinations
    When I view the case determination history
    Then I should see all 3 determinations in chronological order

  Scenario: Record denial with reasons
    Given a case exists for patient "Jane Doe"
    When staff denies eligibility with reason "Patient does not reside in service area"
    Then a determination should be recorded
    And the determination outcome should be "denied"
    And the determination reasons should include "Patient does not reside in service area"

  Scenario: Record deferral pending alternate resources
    Given a case exists for patient "Jane Doe"
    And a PRC referral exists
    When the referral is deferred pending Medicare enrollment
    Then the determination outcome should be "deferred"
    And the determination reasons should include "Medicare enrollment"
