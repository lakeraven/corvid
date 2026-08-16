Feature: PRC management approval gate
  As a tribal health officer
  I need every PRC referral to require management approval before advancing
  So that the 53/60 "no management approval" audit finding is eliminated

  Background:
    Given a tenant "tnt_brokenrock" with facility "fac_main_clinic"
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

  # --- #478 approval-gate controls ---

  Scenario: A specialist cannot approve their own determination (dual control)
    Given the referral was submitted by "spec_iselda"
    And the referral is in "management_approval" status
    And an eligibility checklist with all non-approval items complete
    When manager "spec_iselda" approves the referral
    Then the referral should remain in "management_approval" status
    And the eligibility checklist should not have management approval

  Scenario: A different approver satisfies dual control
    Given the referral was submitted by "spec_iselda"
    And the referral is in "management_approval" status
    And an eligibility checklist with all non-approval items complete
    When manager "pr_mgr_cookie" approves the referral
    Then the referral should be in "alternate_resource_review" status
    And the eligibility checklist should have management approval by "pr_mgr_cookie"

  Scenario: Manager returns an incomplete determination for correction
    Given the referral is in "management_approval" status
    And an eligibility checklist with all non-approval items complete
    When manager "pr_mgr_cookie" returns the referral with reason "residency proof illegible"
    Then the referral should be in "eligibility_review" status
    And the eligibility checklist should not have management approval

  Scenario: Editing eligibility after approval invalidates the approval
    Given the referral is in "management_approval" status
    And an eligibility checklist with all non-approval items complete
    And manager "pr_mgr_cookie" approves the referral
    When the "residency_verified" eligibility item is withdrawn
    Then the referral should be in "eligibility_review" status
    And the eligibility checklist should not have management approval
