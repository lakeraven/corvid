Feature: PRC audit compliance report
  As a tribal health officer
  I need an audit compliance report showing documentation completeness
  So that I can demonstrate to auditors that Finding #2023-005 is resolved

  Background:
    Given a tenant "tnt_yakama" with facility "fac_toppenish"

  Scenario: 100% compliance when all checklists are complete
    Given 10 PRC referrals with complete eligibility checklists
    When I generate the compliance summary
    Then every audit category should show 100% compliance
    And the total referrals should be 10

  Scenario: Deficiency report shows referrals with missing items
    Given 8 PRC referrals with complete eligibility checklists
    And 2 PRC referrals missing management approval
    When I generate the deficiency report
    Then 2 referrals should appear in the deficiency report
    And each deficient referral should list "management_approved" as missing

  Scenario: Sample audit of 10 referrals returns per-category pass rates
    Given 10 PRC referrals with complete eligibility checklists
    When I run a sample audit of 10 referrals
    Then the sample audit should show 10 of 10 with complete applications
    And the sample audit should show 10 of 10 with identity documentation
    And the sample audit should show 10 of 10 with insurance verification
    And the sample audit should show 10 of 10 with residency verification
    And the sample audit should show 10 of 10 with tribal enrollment
    And the sample audit should show 10 of 10 with management approval

  Scenario: Sample audit detects deficiencies
    Given 8 PRC referrals with complete eligibility checklists
    And 2 PRC referrals missing identity verification
    When I run a sample audit of 10 referrals
    Then the sample audit should show 8 of 10 with identity documentation
