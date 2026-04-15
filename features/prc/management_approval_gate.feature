Feature: PRC management approval gate
  As a tribal health officer
  I need every PRC referral to require management approval before advancing
  So that the 53/60 "no management approval" audit finding is eliminated

  Background:
    Given a tenant "tnt_yakama" with facility "fac_toppenish"
    And a patient "pt_001" with a PRC case
    And a PRC referral "rf_001" for that case

  Scenario: Referral cannot skip management approval
    Given the referral is in "eligibility_review" status
    And an eligibility checklist with all non-approval items complete
    When I try to advance directly to alternate resource review
    Then the referral should remain in "eligibility_review" status

  Scenario: Referral advances to management approval when 6/7 items complete
    Given the referral is in "eligibility_review" status
    And an eligibility checklist with all non-approval items complete
    When I request management approval
    Then the referral should be in "management_approval" status

  Scenario: Referral cannot request management approval with incomplete checklist
    Given the referral is in "eligibility_review" status
    And an eligibility checklist with only 3 items complete
    When I request management approval
    Then the referral should remain in "eligibility_review" status

  Scenario: Manager approves and referral advances
    Given the referral is in "management_approval" status
    And an eligibility checklist with all non-approval items complete
    When manager "pr_mgr_cookie" approves the referral
    Then the referral should be in "alternate_resource_review" status
    And the eligibility checklist should have management approval by "pr_mgr_cookie"

  Scenario: Full workflow from eligibility review through management approval
    Given the referral is in "eligibility_review" status
    And an eligibility checklist with all non-approval items complete
    When I request management approval
    And manager "pr_mgr_cookie" approves the referral
    Then the referral should be in "alternate_resource_review" status
    And the eligibility checklist should be complete
