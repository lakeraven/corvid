Feature: PRC referral workflow — staff view
  As PRC program staff (Referral Specialist and PRC Director)
  I want each referral to move through the purchased/referred-care workflow in order
  So that no referral is authorized without complete eligibility documentation and
  the PRC Director's approval, and every decision — approve, deny, defer — is deliberate.

  # This is the workflow as staff experience it. It is the ordered path, the rules that block skipping steps, committee
  # routing for high-cost/high-priority care, and the terminal decisions.

  Background:
    Given a tenant "tnt_brokenrock" with facility "fac_main_clinic"
    And a patient "pt_001" with a PRC case
    And a PRC referral "rf_001" for that case

  Scenario: A new referral begins in draft
    Then the referral should be "in draft"

  Scenario: A referral moves through the full workflow to authorization
    Given the referral was submitted by the Referral Specialist "spec_iselda"
    When the Referral Specialist submits the referral
    Then the referral should be "submitted"
    When the Referral Specialist begins eligibility review
    Then the referral should be "under eligibility review"
    When the eligibility documentation is complete
    And the Referral Specialist requests management approval
    Then the referral should be "awaiting management approval"
    When the PRC Director "dir_cookie" approves the referral
    Then the referral should be "in alternate-resource review"
    When the Referral Specialist verifies alternate resources
    Then the referral should be "in priority assignment"
    When the Referral Specialist completes priority assignment
    Then the referral should be "authorized"

  # --- The PRC Director's approval cannot be skipped ---

  Scenario: A brand-new referral cannot be authorized
    Then the PRC program cannot authorize the referral
    And the PRC Director cannot yet approve the referral

  Scenario: A referral under eligibility review cannot jump to authorization
    Given the referral is "under eligibility review"
    Then the PRC program cannot authorize the referral
    And the Referral Specialist cannot complete priority assignment

  Scenario: The PRC Director cannot be asked to approve an incomplete file
    Given the referral is "under eligibility review"
    And the eligibility documentation is incomplete
    Then the Referral Specialist cannot request management approval

  # --- High-cost / high-priority care goes before the committee ---

  Scenario: A low-cost referral is authorized without committee review
    Given the referral has reached "in priority assignment"
    And the referral does not require committee review
    When the Referral Specialist completes priority assignment
    Then the referral should be "authorized"

  Scenario: A referral that requires committee review goes before the committee first
    Given the referral has reached "in priority assignment"
    And the referral requires committee review
    When the Referral Specialist completes priority assignment
    Then the referral should be "before the review committee"
    When the committee authorizes the referral
    Then the referral should be "authorized"

  # --- Deliberate terminal decisions ---

  Scenario: The PRC program denies a referral during eligibility review
    Given the referral is "under eligibility review"
    When the PRC program denies the referral
    Then the referral should be "denied"

  Scenario: A referral is deferred when funds are unavailable
    Given the referral has reached "in priority assignment"
    When the PRC program defers the referral
    Then the referral should be "deferred"

  Scenario: A denied referral cannot be revived through the workflow
    Given the referral is "under eligibility review"
    When the PRC program denies the referral
    Then the referral should be "denied"
    And the Referral Specialist cannot re-submit the referral
    And the PRC program cannot authorize the referral

  # --- Returning a referral for correction, and cancelling ---

  Scenario: The PRC Director returns a referral for correction
    Given the referral has reached "awaiting management approval"
    When the PRC Director "dir_cookie" returns the referral for correction
    Then the referral should be "under eligibility review"
    And the referral is not yet approved

  Scenario: Changing the eligibility file after approval sends it back for re-approval
    Given the referral has reached "in alternate-resource review"
    When an eligibility item is withdrawn after approval
    Then the referral should be "under eligibility review"
    And the referral is not yet approved

  Scenario: A referral can be cancelled while in progress
    When the Referral Specialist submits the referral
    And the Referral Specialist cancels the referral
    Then the referral should be "cancelled"
