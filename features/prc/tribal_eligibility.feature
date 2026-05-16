Feature: Tribal eligibility decision matrix (TribalEligibilityService)
  As a PRC clerk
  I want eligibility decisions to be structurally correct and audit-defensible
  So that audit findings around enrollment documentation are addressed automatically

  Background:
    Given a tenant "tnt_test" with facility "fac_demo"
    And facility "fac_demo" has contracted tribe code "DEMO"

  Scenario: True positive — enrolled in contracted tribe, all checks pass
    Given person "pt_tp" is enrolled in tribe "DEMO" with confidence verified
    When I decide eligibility for person "pt_tp" at facility "fac_demo"
    Then the decision should be eligible
    And the reason codes should not include any hard-fail reason

  Scenario: True negative — not enrolled
    When I decide eligibility for person "pt_tn" at facility "fac_demo"
    Then the decision should be ineligible
    And the reason codes should include "not_enrolled"

  Scenario: Would-be false positive — wrong-tribe enrollee is correctly denied
    Given person "pt_wfp" is enrolled in tribe "OTHER" with confidence verified
    When I decide eligibility for person "pt_wfp" at facility "fac_demo"
    Then the decision should be ineligible
    And the reason codes should include "not_enrolled_in_contracted_tribe"

  Scenario: Would-be false negative — stale data is not a hard fail
    Given person "pt_wfn" is enrolled in tribe "DEMO" with confidence stale
    When I decide eligibility for person "pt_wfn" at facility "fac_demo"
    Then the decision should be eligible
    And the reason codes should include "enrollment_stale"
    And the reason codes should not include any hard-fail reason

  Scenario: Persistence — every decide writes a PrcEligibilityDecision row
    Given person "pt_persist" is enrolled in tribe "DEMO" with confidence verified
    When I decide eligibility for person "pt_persist" at facility "fac_demo"
    Then exactly 1 PrcEligibilityDecision row should exist for person "pt_persist"
    And that row should have the provider confidence "verified"
